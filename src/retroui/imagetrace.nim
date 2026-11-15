## Image Trace: a picture made vector shapes -- its colors found, the areas
## of each traced along their edges and drawn again as smooth curves with
## corners where the picture has them. For a photo as a flat illustration,
## a scanned logo or drawing as paths, a sketch as ink lines.
##
## ```nim
## let r = traceImage(px, w, h, tracePreset(tp6Colors))
## for s in r.shapes: discard d.addShapeLayer(ShapeData(path: s.path, fill: solidPaint(s.color)))
## writeFile("traced.svg", tracedSvg(r))
## ```
##
## How: the picture is cut to `colors` colors (k-means, from a sample of
## it; or grays, or black and white at a threshold), areas smaller than
## `noise` pixels go to the color round them, and each color is traced
## along the pixels' edges. The outlines are simplified (`paths`: how
## closely they follow the pixels) and drawn as curves through their
## points, sharp where they turn more than `corners` allows. Stacked (the
## default), each color's shape also covers the colors drawn above it, so
## there is never a gap between two shapes.
##
## Work is linear in the pixels for each color; a picture bigger than
## `maxSide` is traced at that size and the shapes scaled back.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, algorithm, strutils]
import photo

type
  TraceMode* = enum
    tmColor = "Color", tmGray = "Grayscale", tmBlackWhite = "Black and White"
  TracePreset* = enum
    ## Ready settings, as the Image Trace panel offers them.
    tpDefault = "Default", tpHighPhoto = "High Fidelity Photo", tpLowPhoto = "Low Fidelity Photo",
    tp3Colors = "3 Colors", tp6Colors = "6 Colors", tp16Colors = "16 Colors", tpGrays = "Shades of Gray",
    tpLogo = "Black and White Logo", tpSketch = "Sketched Art", tpSilhouettes = "Silhouettes"
  TraceOptions* = object
    mode*: TraceMode
    colors*: int        ## color and grayscale: how many (2 .. 64)
    threshold*: int     ## black and white: lighter than this is white (0 .. 255)
    paths*: float       ## 0 .. 1: how closely the outlines follow the pixels (1: closest)
    corners*: float     ## 0 .. 1: how readily a turn is a corner rather than a curve (1: most)
    noise*: int         ## areas smaller than this many pixels are left out (merged into what is round them)
    blur*: float        ## the picture softened first, this many pixels (0: not)
    ignoreWhite*: bool  ## no shape for white (what is white is left empty)
    stacked*: bool      ## each color's shape covers the colors above it too: no gaps (else: side by side)
    maxSide*: int       ## a picture bigger than this is traced at this size (0: 2400)
  TracedShape* = object
    color*: uint32      ## its fill, ARGB
    path*: Path         ## its outlines (one shape, holes in it), in the picture's pixels
    area*: int          ## how many pixels of the picture are this color
  TraceResult* = object
    w*, h*: int         ## the picture's size
    shapes*: seq[TracedShape]   ## from the bottom up
    points*: int        ## anchor points in all

const Dirs = [(1, 0), (0, 1), (-1, 0), (0, -1)]   # (right, down, left, up)

proc tracePreset*(p: TracePreset): TraceOptions =
  ## A preset's settings.
  result = TraceOptions(mode: tmColor, colors: 6, threshold: 128, paths: 0.5, corners: 0.25, noise: 25,
                        stacked: true)
  case p
  of tpDefault: result.mode = tmBlackWhite
  of tpHighPhoto: result.colors = 32; result.paths = 0.85; result.noise = 4; result.corners = 0.1
  of tpLowPhoto: result.colors = 12; result.paths = 0.55; result.noise = 25; result.blur = 1
  of tp3Colors: result.colors = 3; result.noise = 40
  of tp6Colors: result.colors = 6
  of tp16Colors: result.colors = 16; result.paths = 0.6; result.noise = 16
  of tpGrays: result.mode = tmGray; result.colors = 8; result.noise = 16
  of tpLogo: result.mode = tmBlackWhite; result.paths = 0.75; result.corners = 0.5; result.noise = 12
  of tpSketch:
    result.mode = tmBlackWhite; result.threshold = 150; result.ignoreWhite = true
    result.paths = 0.7; result.noise = 6; result.corners = 0.35
  of tpSilhouettes:
    result.mode = tmBlackWhite; result.threshold = 200; result.ignoreWhite = true
    result.paths = 0.4; result.noise = 60

# ---- colors --------------------------------------------------------------------------------------------

proc lumOf(c: uint32): int {.inline.} =
  (int((c shr 16) and 255) * 77 + int((c shr 8) and 255) * 150 + int(c and 255) * 29) shr 8

proc dist(a, b: array[3, float]): float {.inline.} =
  # (weighted: the eye tells greens apart best)
  let dr = a[0] - b[0]
  let dg = a[1] - b[1]
  let db = a[2] - b[2]
  dr * dr * 2 + dg * dg * 4 + db * db * 3

proc rgbOf(c: uint32): array[3, float] {.inline.} =
  [float((c shr 16) and 255), float((c shr 8) and 255), float(c and 255)]

proc kmeans(samples: seq[array[3, float]]; k: int): seq[array[3, float]] =
  ## (k centers: chosen k-means++ from the samples, then moved 12 times)
  if samples.len == 0: return
  var seed = 0x9E3779B9'u32
  proc rnd(): float =
    seed = seed xor (seed shl 13)
    seed = seed xor (seed shr 17)
    seed = seed xor (seed shl 5)
    float(seed) / 4294967296.0
  result.add samples[samples.len div 2]
  var dmin = newSeq[float](samples.len)
  for i in 0 ..< samples.len: dmin[i] = dist(samples[i], result[0])
  while result.len < k:
    var total = 0.0
    for d in dmin: total += d
    if total <= 0: break                       # (fewer colors than asked)
    var t = rnd() * total
    var pick = samples.high
    for i in 0 ..< samples.len:
      t -= dmin[i]
      if t <= 0:
        pick = i
        break
    result.add samples[pick]
    for i in 0 ..< samples.len: dmin[i] = min(dmin[i], dist(samples[i], result[^1]))
  var sums = newSeq[array[4, float]](result.len)
  for _ in 0 ..< 12:
    for s in sums.mitems: s = [0.0, 0, 0, 0]
    for p in samples:
      var best = 0
      var bd = Inf
      for j in 0 ..< result.len:
        let d = dist(p, result[j])
        if d < bd:
          bd = d
          best = j
      sums[best][0] += p[0]; sums[best][1] += p[1]; sums[best][2] += p[2]; sums[best][3] += 1
    var moved = false
    for j in 0 ..< result.len:
      if sums[j][3] > 0:
        let c = [sums[j][0] / sums[j][3], sums[j][1] / sums[j][3], sums[j][2] / sums[j][3]]
        if dist(c, result[j]) > 0.25: moved = true
        result[j] = c
    if not moved: break

proc softened(px: openArray[uint32]; w, h: int; radius: float): seq[uint32] =
  ## (three box blurs of the colors, alpha kept)
  result = @px
  let r = max(1, int(radius * 0.58 + 0.5))
  var tmp = newSeq[uint32](px.len)
  for _ in 0 ..< 3:
    for pass in 0 .. 1:
      let (n, m, step, lineStep) = if pass == 0: (w, h, 1, w) else: (h, w, w, 1)
      for line in 0 ..< m:
        let base = line * lineStep
        var acc: array[3, int]
        var cnt = 0
        for i in -r .. r:
          let j = clamp(i, 0, n - 1)
          let c = result[base + j * step]
          acc[0] += int((c shr 16) and 255); acc[1] += int((c shr 8) and 255); acc[2] += int(c and 255)
          inc cnt
        for i in 0 ..< n:
          let c0 = result[base + i * step]
          tmp[base + i * step] = (c0 and 0xFF000000'u32) or (uint32(acc[0] div cnt) shl 16) or
                                 (uint32(acc[1] div cnt) shl 8) or uint32(acc[2] div cnt)
          let a = result[base + clamp(i - r, 0, n - 1) * step]
          let b = result[base + clamp(i + r + 1, 0, n - 1) * step]
          acc[0] += int((b shr 16) and 255) - int((a shr 16) and 255)
          acc[1] += int((b shr 8) and 255) - int((a shr 8) and 255)
          acc[2] += int(b and 255) - int(a and 255)
      swap(result, tmp)

proc labelled(px: openArray[uint32]; w, h: int; o: TraceOptions;
              palette: var seq[uint32]): seq[int16] =
  ## (each pixel's color, as an index into `palette`; -1: transparent)
  result = newSeq[int16](w * h)
  case o.mode
  of tmBlackWhite:
    palette = @[0xFF000000'u32, 0xFFFFFFFF'u32]
    let t = clamp(o.threshold, 0, 255)
    for i in 0 ..< px.len:
      result[i] = if (px[i] shr 24) < 128: -1'i16 elif lumOf(px[i]) < t: 0'i16 else: 1'i16
  of tmGray, tmColor:
    let k = clamp(o.colors, 2, 64)
    # a sample of the picture (at most 12,000 pixels, spread evenly)
    var samples: seq[array[3, float]]
    let step = max(1, px.len div 12_000)
    var i = (step - 1) div 2
    while i < px.len:
      let c = px[i]
      if (c shr 24) >= 128:
        if o.mode == tmGray:
          let l = lumOf(c).float
          samples.add [l, l, l]
        else: samples.add rgbOf(c)
      i += step
    let centers = kmeans(samples, k)
    palette = @[]
    for c in centers:
      palette.add 0xFF000000'u32 or (uint32(clamp(int(c[0] + 0.5), 0, 255)) shl 16) or
                  (uint32(clamp(int(c[1] + 0.5), 0, 255)) shl 8) or uint32(clamp(int(c[2] + 0.5), 0, 255))
    if palette.len == 0: palette = @[0xFFFFFFFF'u32]
    # each color to its nearest, by a table of 32,768 colors (5 bits a channel)
    var table = newSeq[int16](32768)
    for q in 0 ..< 32768:
      let c = [float((q shr 10) and 31) * 8.226, float((q shr 5) and 31) * 8.226, float(q and 31) * 8.226]
      let cc = if o.mode == tmGray: (let l = (c[0] * 77 + c[1] * 150 + c[2] * 29) / 256; [l, l, l]) else: c
      var best = 0
      var bd = Inf
      for j in 0 ..< centers.len:
        let d = dist(cc, centers[j])
        if d < bd:
          bd = d
          best = j
      table[q] = int16(best)
    for i in 0 ..< px.len:
      let c = px[i]
      if (c shr 24) < 128:
        result[i] = -1
      else:
        let q = int(((c shr 19) and 31) shl 10) or int(((c shr 11) and 31) shl 5) or int((c shr 3) and 31)
        result[i] = table[q]

proc despeckle(lab: var seq[int16]; w, h, least: int) =
  ## (areas of fewer than `least` pixels given the color most of their edge touches)
  if least <= 1: return
  var comp = newSeq[int32](w * h)
  for i in 0 ..< comp.len: comp[i] = -1
  var stack: seq[int32]
  var members: seq[int32]
  var counts: seq[int]
  var next = 0'i32
  for start in 0 ..< w * h:
    if comp[start] >= 0 or lab[start] < 0: continue
    let c = lab[start]
    stack.setLen(0)
    members.setLen(0)
    stack.add int32(start)
    comp[start] = next
    while stack.len > 0:
      let p = stack.pop()
      members.add p
      let x = p mod w.int32
      let y = p div w.int32
      for (dx, dy) in Dirs:
        let nx = x + dx.int32
        let ny = y + dy.int32
        if nx < 0 or ny < 0 or nx >= w.int32 or ny >= h.int32: continue
        let q = ny * w.int32 + nx
        if comp[q] < 0 and lab[q] == c:
          comp[q] = next
          stack.add q
    inc next
    if members.len >= least: continue
    # (small: the color round it)
    if counts.len < 64: counts.setLen(64)
    for k in 0 ..< counts.len: counts[k] = 0
    var any = false
    for p in members:
      let x = p mod w.int32
      let y = p div w.int32
      for (dx, dy) in Dirs:
        let nx = x + dx.int32
        let ny = y + dy.int32
        if nx < 0 or ny < 0 or nx >= w.int32 or ny >= h.int32: continue
        let q = lab[ny * w.int32 + nx]
        if q >= 0 and q != c:
          inc counts[q]
          any = true
    if not any: continue
    var best = 0
    for k in 1 ..< counts.len:
      if counts[k] > counts[best]: best = k
    for p in members: lab[p] = int16(best)

# ---- outlines ------------------------------------------------------------------------------------------

type Pt = (float, float)

proc contours(inside: proc (i: int): bool {.closure.}; w, h: int; least: int): seq[seq[Pt]] =
  ## (the outlines of the pixels `inside` says are in, along their edges: the inside on the
  ## right of the way they go -- outer edges clockwise on screen, holes the other way)
  let vw = w + 1
  var bits = newSeq[uint8](vw * (h + 1))
  for y in 0 ..< h:
    for x in 0 ..< w:
      if not inside(y * w + x): continue
      if y == 0 or not inside((y - 1) * w + x): bits[y * vw + x] = bits[y * vw + x] or 1          # right, along its top
      if x == w - 1 or not inside(y * w + x + 1): bits[y * vw + x + 1] = bits[y * vw + x + 1] or 2   # down, its right
      if y == h - 1 or not inside((y + 1) * w + x):
        bits[(y + 1) * vw + x + 1] = bits[(y + 1) * vw + x + 1] or 4                              # left, its bottom
      if x == 0 or not inside(y * w + x - 1): bits[(y + 1) * vw + x] = bits[(y + 1) * vw + x] or 8  # up, its left
  for v0 in 0 ..< bits.len:
    while bits[v0] != 0:
      var d = 0
      while (bits[v0] and uint8(1 shl d)) == 0: inc d
      var v = v0
      var pts = @[(float(v0 mod vw), float(v0 div vw))]
      var last = -1
      var area = 0
      var guard = 0
      while true:
        bits[v] = bits[v] and not uint8(1 shl d)
        if last >= 0 and d != last: pts.add (float(v mod vw), float(v div vw))
        let (dx, dy) = Dirs[d]
        area += (v mod vw) * dy - (v div vw) * dx     # (twice the area, as it goes)
        v += dy * vw + dx
        last = d
        if v == v0: break
        inc guard
        if guard > 8 * bits.len: break
        let b = bits[v]
        if b == 0: break
        # (two ways on at a corner where pixels touch diagonally: the right turn first)
        let r = (last + 1) mod 4
        let l = (last + 3) mod 4
        d = if (b and uint8(1 shl r)) != 0: r elif (b and uint8(1 shl last)) != 0: last
            elif (b and uint8(1 shl l)) != 0: l else: (last + 2) mod 4
      if abs(area) div 2 >= least and pts.len >= 3: result.add pts

proc simplified(pts: seq[Pt]; tol: float): seq[Pt] =
  ## (a closed outline with fewer points: Douglas-Peucker, from its two points farthest apart)
  let n = pts.len
  if n <= 4: return pts
  var far = 0
  var fd = -1.0
  for i in 1 ..< n:
    let d = (pts[i][0] - pts[0][0]) ^ 2 + (pts[i][1] - pts[0][1]) ^ 2
    if d > fd:
      fd = d
      far = i
  var keep = newSeq[bool](n)
  keep[0] = true
  keep[far] = true
  var stack = @[(0, far), (far, n)]
  let t2 = tol * tol
  while stack.len > 0:
    let (a, b) = stack.pop()
    if b - a < 2: continue
    let p = pts[a]
    let q = pts[b mod n]
    let dx = q[0] - p[0]
    let dy = q[1] - p[1]
    let len2 = dx * dx + dy * dy
    var best = -1
    var bd = t2
    for i in a + 1 ..< b:
      let r = pts[i]
      let d = if len2 <= 1e-12: (r[0] - p[0]) ^ 2 + (r[1] - p[1]) ^ 2
              else: (dy * (r[0] - p[0]) - dx * (r[1] - p[1])) ^ 2 / len2
      if d > bd:
        bd = d
        best = i
    if best >= 0:
      keep[best] = true
      stack.add (a, best)
      stack.add (best, b)
  for i in 0 ..< n:
    if keep[i]: result.add pts[i]

proc curved(pts: seq[Pt]; cornerTurn: float): SubPath =
  ## (the points as a closed curve: handles along the way the outline goes, a third of the
  ## way to the points beside; a turn sharper than `cornerTurn` radians a corner)
  result = SubPath(closed: true)
  let n = pts.len
  for i in 0 ..< n:
    let p = pts[i]
    let a = pts[(i + n - 1) mod n]
    let b = pts[(i + 1) mod n]
    let ax = p[0] - a[0]
    let ay = p[1] - a[1]
    let bx = b[0] - p[0]
    let by = b[1] - p[1]
    let la = sqrt(ax * ax + ay * ay)
    let lb = sqrt(bx * bx + by * by)
    var pp = PathPoint(p: p, inH: p, outH: p)
    if la > 1e-9 and lb > 1e-9:
      let turn = arccos(clamp((ax * bx + ay * by) / (la * lb), -1.0, 1.0))
      if turn < cornerTurn:
        var tx = b[0] - a[0]
        var ty = b[1] - a[1]
        let tl = sqrt(tx * tx + ty * ty)
        if tl > 1e-9:
          tx /= tl
          ty /= tl
          pp.inH = (p[0] - tx * la / 3, p[1] - ty * la / 3)
          pp.outH = (p[0] + tx * lb / 3, p[1] + ty * lb / 3)
    result.pts.add pp

# ---- the trace -----------------------------------------------------------------------------------------

proc traceImage*(px: openArray[uint32]; w, h: int; o: TraceOptions): TraceResult =
  ## The picture `px` (`w` x `h`, ARGB) as filled shapes, from the bottom
  ## up: one a color, each with its outlines and holes. Transparent pixels
  ## are left out.
  result = TraceResult(w: w, h: h)
  if w <= 0 or h <= 0 or px.len < w * h: return
  let most = if o.maxSide > 0: o.maxSide else: 2400
  # (big: traced smaller, the shapes scaled back)
  var tw = w
  var th = h
  var src: seq[uint32]
  if max(w, h) > most:
    let k = most / max(w, h)
    tw = max(1, int(w.float * k + 0.5))
    th = max(1, int(h.float * k + 0.5))
    src = newSeq[uint32](tw * th)
    for y in 0 ..< th:
      let sy = min(h - 1, int((y.float + 0.5) * h.float / th.float))
      for x in 0 ..< tw:
        src[y * tw + x] = px[sy * w + min(w - 1, int((x.float + 0.5) * w.float / tw.float))]
  else:
    src = newSeq[uint32](w * h)
    for i in 0 ..< w * h: src[i] = px[i]
  let sx = w / tw
  let sy = h / th
  if o.blur >= 0.5: src = softened(src, tw, th, o.blur)
  var palette: seq[uint32]
  var lab = labelled(src, tw, th, o, palette)
  let least = max(1, int(o.noise.float / (sx * sy) + 0.5))
  despeckle(lab, tw, th, least)
  # each color's area; the order they are drawn: the biggest at the bottom
  var areas = newSeq[int](palette.len)
  for l in lab:
    if l >= 0: inc areas[l]
  var order: seq[int]
  for j in 0 ..< palette.len:
    if areas[j] > 0: order.add j
  order.sort(proc (a, b: int): int = cmp(areas[b], areas[a]))
  var rank = newSeq[int](palette.len)
  for r, j in order: rank[j] = r
  let tol = 0.75 + (1 - clamp(o.paths, 0.0, 1.0)) * 2.5
  let cornerTurn = degToRad(85.0 - clamp(o.corners, 0.0, 1.0) * 60.0)
  for r, j in order:
    let c = palette[j]
    if o.ignoreWhite and lumOf(c) >= 235 and (abs(int((c shr 16) and 255) - int(c and 255)) < 24): continue
    let ranks = rank
    let labs = addr lab
    let stacked = o.stacked
    let inside = proc (i: int): bool =
      let l = labs[][i]
      l >= 0 and (if stacked: ranks[l] >= r else: l == j)
    var path = Path(name: "Traced " & $(r + 1))
    for outline in contours(inside, tw, th, least):
      var pts = simplified(outline, tol)
      if pts.len < 3: continue
      if sx != 1 or sy != 1:
        for q in pts.mitems: q = (q[0] * sx, q[1] * sy)
      var sp = curved(pts, cornerTurn)
      sp.joined = path.subs.len > 0
      result.points += sp.pts.len
      path.subs.add sp
    if path.subs.len > 0:
      result.shapes.add TracedShape(color: c, path: path, area: int(areas[j].float * sx * sy))

proc tracedSvg*(r: TraceResult): string =
  ## The traced shapes as an SVG drawing.
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" & $r.w & "\" height=\"" & $r.h &
           "\" viewBox=\"0 0 " & $r.w & " " & $r.h & "\">\n"
  proc f(v: float): string = formatFloat(v, ffDecimal, 2).strip(leading = false, chars = {'0'}).strip(leading = false, chars = {'.'})
  for s in r.shapes:
    var d = ""
    for sp in s.path.subs:
      if sp.pts.len == 0: continue
      d.add "M" & f(sp.pts[0].p[0]) & " " & f(sp.pts[0].p[1])
      for i in 0 ..< sp.pts.len:
        let a = sp.pts[i]
        let b = sp.pts[(i + 1) mod sp.pts.len]
        if a.outH == a.p and b.inH == b.p:
          d.add "L" & f(b.p[0]) & " " & f(b.p[1])
        else:
          d.add "C" & f(a.outH[0]) & " " & f(a.outH[1]) & " " & f(b.inH[0]) & " " & f(b.inH[1]) & " " &
                f(b.p[0]) & " " & f(b.p[1])
      d.add "Z"
    result.add "<path fill=\"#" & toHex(int(s.color and 0xFFFFFF), 6).toLowerAscii & "\" d=\"" & d & "\"/>\n"
  result.add "</svg>\n"
