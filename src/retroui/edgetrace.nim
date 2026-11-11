## The edges of a picture, found and linked into lines: the engine of
## Retro Photo's tracing tool (as Photoshop's Content-Aware Tracing
## Tool). Over the picture the nearest strong edge lights up (`chainAt`,
## `chainPoints`); a click makes it a path (`photopaint.fitPath` of its
## points); Shift+click on another edge adds that one (`chainPart` for a
## stretch of it from one point to another).
##
## .. code-block:: nim
##   let m = newEdgeMap(layer, detail = 50)       # once, when the tool is picked
##   let i = m.chainAt(mouseX, mouseY, 12)        # as the pointer moves
##   if i >= 0:
##     let sub = fitPath(m.chainPoints(i), 2.0, closed = m.chainClosed(i))
##
## `newEdgeMap` finds the edges as Canny's detector does: the picture
## blurred a little (more for a low `detail`); how fast red, green and
## blue each change at each pixel (Sobel), the channel that changes most
## counting -- so an edge between two colors of the same lightness is
## found too, and where the picture is transparent, its alpha (the colors
## there weighed by it: those of fully transparent pixels do not count);
## of those only the pixels where the change is greatest across the edge;
## of those the strong ones and the weaker ones (down to 0.4 of it) joined
## to them. Strong is the strongest part of this picture's edges -- about
## a quarter at detail 50, 1 % at detail 1, 90 % at 100 -- but always a
## change of 42 levels across at detail 50 (100 at 1, 10 at 100) and
## never one too faint to see. The edge pixels are then followed into
## chains: a chain ends where its line ends or branches (a short spur does
## not split it); chains shorter than 12 - `detail` / 10 pixels are dropped.
##
## Coordinates are the picture's pixels with (0, 0) the top-left corner
## of the top-left pixel: pixel (x, y) covers x ..< x + 1, y ..< y + 1,
## as for paths and selections. A chain's points lie on the edge to
## about a tenth of a pixel on average, one a grid pixel along it, in
## order. Within a few pixels of the picture's border an edge is less
## sure: the blur takes the border as going on.
##
## A picture of more than `maxTracePixels` (6 megapixels) is traced on a
## smaller copy: each `scale` x `scale` square of pixels averaged, with
## `scale` the smallest whole number that brings it to 6 megapixels or
## less (2 for a 4000 x 3000 photo, 3 for 8000 x 6000). The chains'
## points are scaled back to the picture's pixels (so about `scale`
## pixels apart); `strength` and `index` stay those of the copy (the
## grid, `gw` x `gh`): a picture pixel (x, y) is grid pixel
## (x div `scale`, y div `scale`). A 4000 x 3000 photo takes 0.2 to 0.4
## seconds on one core; while it works it takes up to 18 bytes a grid
## pixel (108 MB at 6 megapixels), and the map keeps 5 (`index`,
## `strength`) and the chains.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, bitops]
import gfx

const
  maxTracePixels* = 6_000_000
    ## A picture with more pixels than this is traced on a copy made
    ## smaller by a whole number (`EdgeMap.scale`).

type
  EdgeMap* = ref object
    ## The edges of a picture (`newEdgeMap`): how strong the change is at
    ## each pixel, and the edges linked into chains of points along them.
    w*, h*: int                        ## the picture's size
    scale*: int                        ## picture pixels a side per grid pixel: 1, more for a picture over `maxTracePixels`
    gw*, gh*: int                      ## the grid's size (of `strength` and `index`): the picture's / `scale`, rounded up
    detail*: int                       ## the `detail` it was made with
    strength*: seq[uint8]              ## how much the picture changes at each grid pixel (after the blur): 0 not at all, about 200 a sharp black-to-white edge
    index*: seq[int32]                 ## the chain through each grid pixel, -1 none (a pixel where chains meet: one of them)
    chains*: seq[seq[(float, float)]]  ## each edge's points in order along it, in picture pixels

const
  fCand = 4'u8        # (info: bits 0-1 the direction across the edge) a maximum across the edge
  fEdge = 8'u8        # an edge pixel: kept by the thresholds
  fUsed = 16'u8       # (tracing) in a chain already
  histBins = 1024     # (the strength histogram: a quarter level per pixel a bin)

proc ringComponents(m: int): int =
  ## (how many separate groups the set neighbours of `m` make, 8-connected:
  ## bit 0 east, then clockwise -- south-east, south, ... north-east)
  var f = m
  for k in [1, 3, 5, 7]:            # (a corner between two set sides joins them)
    if (m and (1 shl (k - 1))) != 0 and (m and (1 shl ((k + 1) and 7))) != 0: f = f or (1 shl k)
  if f == 255: return 1
  for k in 0 .. 7:
    if (f and (1 shl k)) != 0 and (f and (1 shl ((k + 7) and 7))) == 0: inc result

const ringComps = block:
  var t: array[256, uint8]
  for m in 0 .. 255: t[m] = uint8(ringComponents(m))
  t

proc gaussKernel(sigma: float): seq[float32] =
  let r = max(1, int(ceil(sigma * 3.0 - 0.25)))
  var k = newSeq[float](2 * r + 1)
  var s = 0.0
  for i in -r .. r:
    k[i + r] = exp(-float(i * i) / (2 * sigma * sigma))
    s += k[i + r]
  for v in k: result.add float32(v / s)

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

proc shrunk(b: Bitmap; s, gw, gh: int; premul: bool): seq[uint32] =
  ## (each `s` x `s` square averaged; the colors times alpha with `premul`)
  result = newSeq[uint32](gw * gh)
  var acc = newSeq[int](gw * 4)
  let src = cast[ptr UncheckedArray[uint32]](unsafeAddr b.px[0])
  for gy in 0 ..< gh:
    for v in acc.mitems: v = 0
    let y0 = gy * s
    let y1 = min(b.h, y0 + s)
    for y in y0 ..< y1:
      let row = y * b.w
      for gx in 0 ..< gw:
        let x0 = gx * s
        let x1 = min(b.w, x0 + s)
        var a, r, g, bl = 0
        for x in x0 ..< x1:
          let p = src[row + x]
          let pa = int(p shr 24)
          a += pa
          if premul:
            r += int((p shr 16) and 255) * pa
            g += int((p shr 8) and 255) * pa
            bl += int(p and 255) * pa
          else:
            r += int((p shr 16) and 255)
            g += int((p shr 8) and 255)
            bl += int(p and 255)
        acc[4 * gx] += a; acc[4 * gx + 1] += r; acc[4 * gx + 2] += g; acc[4 * gx + 3] += bl
    for gx in 0 ..< gw:
      let n = (y1 - y0) * (min(b.w, gx * s + s) - gx * s)
      let d = if premul: n * 255 else: n
      let half = d div 2
      result[gy * gw + gx] = (uint32((acc[4 * gx] + n div 2) div n) shl 24) or
        (uint32((acc[4 * gx + 1] + half) div d) shl 16) or
        (uint32((acc[4 * gx + 2] + half) div d) shl 8) or uint32((acc[4 * gx + 3] + half) div d)

proc channelPass(src: ptr UncheckedArray[uint32]; w, h, shift: int; premul: bool; k: seq[float32];
                 tmp, rows, buf, mag2: var seq[float32]; info: var seq[uint8]) =
  ## One channel blurred (across into `tmp`, then down three rows at a
  ## time) and its Sobel gradient: where it is the greatest so far, kept
  ## in `mag2` (squared, times 64) with its direction in `info`.
  let r = k.len div 2
  let t = cast[ptr UncheckedArray[float32]](addr tmp[0])
  let bp = cast[ptr UncheckedArray[float32]](addr buf[0])
  let rp = cast[ptr UncheckedArray[float32]](addr rows[0])
  let mg = cast[ptr UncheckedArray[float32]](addr mag2[0])
  let ip = cast[ptr UncheckedArray[uint8]](addr info[0])
  const inv255 = 1'f32 / 255
  for y in 0 ..< h:
    let row = y * w
    if premul:
      for x in 0 ..< w:
        let p = src[row + x]
        bp[r + x] = float32((p shr shift) and 255) * float32(p shr 24) * inv255
    else:
      for x in 0 ..< w: bp[r + x] = float32((src[row + x] shr shift) and 255)
    for i in 0 ..< r:
      bp[i] = bp[r]
      bp[r + w + i] = bp[r + w - 1]
    let o = cast[ptr UncheckedArray[float32]](addr t[row])
    let k0 = k[0]
    for x in 0 ..< w: o[x] = k0 * bp[x]
    for j in 1 .. 2 * r:
      let kj = k[j]
      let s = cast[ptr UncheckedArray[float32]](addr bp[j])
      for x in 0 ..< w: o[x] += kj * s[x]
  for y in 0 ..< h:
    let o = cast[ptr UncheckedArray[float32]](addr rp[(y mod 3) * w])
    block:
      let kj = k[0]
      let s = cast[ptr UncheckedArray[float32]](addr t[clamp(y - r, 0, h - 1) * w])
      for x in 0 ..< w: o[x] = kj * s[x]
    for j in 1 .. 2 * r:
      let kj = k[j]
      let s = cast[ptr UncheckedArray[float32]](addr t[clamp(y + j - r, 0, h - 1) * w])
      for x in 0 ..< w: o[x] += kj * s[x]
    if y >= 2:
      let a = cast[ptr UncheckedArray[float32]](addr rp[((y - 2) mod 3) * w])
      let b = cast[ptr UncheckedArray[float32]](addr rp[((y - 1) mod 3) * w])
      let c = o
      let base = (y - 1) * w
      for x in 1 ..< w - 1:
        let gx = (a[x + 1] - a[x - 1]) + 2 * (b[x + 1] - b[x - 1]) + (c[x + 1] - c[x - 1])
        let gy = (c[x - 1] + 2 * c[x] + c[x + 1]) - (a[x - 1] + 2 * a[x] + a[x + 1])
        let m = gx * gx + gy * gy
        if m > mg[base + x]:
          mg[base + x] = m
          let ax = abs(gx)
          let ay = abs(gy)
          ip[base + x] =
            if ay <= ax * 0.41421357'f32: 0'u8         # (across: left-right)
            elif ax <= ay * 0.41421357'f32: 2'u8       # (up-down)
            elif (gx > 0) == (gy > 0): 1'u8            # (top-left to bottom-right)
            else: 3'u8                                 # (bottom-left to top-right)

proc thinned(mag: seq[float32]; info: var seq[uint8]; w, h: int): array[histBins, int] =
  ## (non-maximum suppression: the pixels the change is greatest at across
  ## the edge marked; the histogram of their strengths)
  let dOff = [1, w + 1, w, 1 - w]
  let mp = cast[ptr UncheckedArray[float32]](unsafeAddr mag[0])
  let ip = cast[ptr UncheckedArray[uint8]](addr info[0])
  for y in 1 ..< h - 1:
    for x in 1 ..< w - 1:
      let i = y * w + x
      let m = mp[i]
      if m < 0.05'f32: continue
      let d = dOff[int(ip[i] and 3)]
      if m > mp[i - d] and m >= mp[i + d]:
        ip[i] = ip[i] or fCand
        # (counted from a level a pixel -- about 3 levels across the edge: less, as in
        # a clear sky, is no edge anyone sees, and would make every other one strong)
        if m >= 1'f32: inc result[min(histBins - 1, int(m * 4))]

{.pop.}

proc nmask(info: seq[uint8]; p: int; off: array[8, int]): int {.inline.} =
  ## (which of the 8 neighbours of `p` are edge pixels: bit 0 east, clockwise)
  for k in 0 .. 7:
    if (info[p + off[k]] and fEdge) != 0: result = result or (1 shl k)

proc walk(info: var seq[uint8]; off: array[8, int]; start, first: int; startNode: bool): seq[int32] =
  ## (the pixels from `start` through `first` along the line, to the next
  ## end or branch -- or round to `start` again)
  result = @[int32(start)]
  var prev = start
  var cur = first
  while true:
    result.add int32(cur)
    let mk = nmask(info, cur, off)
    if popcount(mk) != 2: break
    info[cur] = info[cur] or fUsed
    var nxt = -1
    for k in 0 .. 7:
      if (mk and (1 shl k)) != 0 and cur + off[k] != prev: nxt = cur + off[k]
    if nxt < 0: break
    if nxt == start:
      if startNode: result.add int32(start)
      break
    if (info[nxt] and fUsed) != 0 and popcount(nmask(info, nxt, off)) == 2: break
    prev = cur
    cur = nxt

type Seg = object
  px: seq[int32]      # grid pixels in order
  a, b: int32         # the branch point at the start and the end, -1 none

proc newEdgeMap*(b: Bitmap; detail = 50): EdgeMap =
  ## The edges of `b`, linked into chains. `detail` (1..100): the higher,
  ## the more and weaker edges kept and the less the picture is blurred
  ## first (sigma 1.6 at 1, 1.0 at 100); at 50 the outlines a person would
  ## trace, little of a texture such as wood grain or grass. A picture over
  ## `maxTracePixels` is traced on a smaller copy (see the module's notes).
  let detail = clamp(detail, 1, 100)
  result = EdgeMap(detail: detail, scale: 1)
  if b == nil or b.w <= 0 or b.h <= 0 or b.px.len < b.w * b.h: return
  result.w = b.w
  result.h = b.h
  var s = 1
  while ((b.w + s - 1) div s) * ((b.h + s - 1) div s) > maxTracePixels: inc s
  let w = (b.w + s - 1) div s
  let h = (b.h + s - 1) div s
  result.scale = s
  result.gw = w
  result.gh = h
  result.index = newSeq[int32](w * h)
  for v in result.index.mitems: v = -1
  result.strength = newSeq[uint8](w * h)
  if w < 3 or h < 3: return
  # ---- the gradient: the strongest of the channels, blurred --------------------------------
  var alpha = false
  for p in b.px:
    if (p shr 24) != 255:
      alpha = true
      break
  # (given at once: Nim 2.2.6 does not free a value first given in an `if`
  # when it is given another -- `small = @[]` below)
  var small = if s > 1: shrunk(b, s, w, h, alpha) else: newSeq[uint32]()
  let src = if s > 1: cast[ptr UncheckedArray[uint32]](addr small[0])
            else: cast[ptr UncheckedArray[uint32]](unsafeAddr b.px[0])
  let sigma = 1.6 - 0.6 * float(detail - 1) / 99
  let k = gaussKernel(sigma)
  var mag = newSeq[float32](w * h)
  var info = newSeq[uint8](w * h)
  block:
    var tmp = newSeq[float32](w * h)
    var rows = newSeq[float32](3 * w)
    var buf = newSeq[float32](w + k.len)
    for shift in [16, 8, 0]:
      channelPass(src, w, h, shift, alpha and s == 1, k, tmp, rows, buf, mag, info)
    if alpha:
      channelPass(src, w, h, 24, false, k, tmp, rows, buf, mag, info)
  small = @[]
  for i in 0 ..< mag.len:
    let m = sqrt(mag[i]) * 0.125'f32                     # (levels a pixel)
    mag[i] = m
    result.strength[i] = uint8(min(255'f32, m * 3 + 0.5))
  # ---- thinned to the greatest change across each edge; the thresholds -----------------------
  let hist = thinned(mag, info, w, h)
  var total = 0
  for c in hist: total += c
  # (the strongest 0.9 % of the maxima across an edge start edges at detail 1, 23 % at
  # 50, 90 % at 100: on photos, more at 50 is wood grain and grass)
  let above = 0.009 + 0.891 * (detail.float / 100) * (detail.float / 100)
  let target = int(ceil(float(total) * (1 - above)))
  var acc = 0
  var bin = 0
  while bin < histBins - 1 and acc + hist[bin] < target:
    acc += hist[bin]
    inc bin
  # (in levels a pixel: below the floor it is noise; a change of `sure` levels across
  # an edge -- 100 at detail 1, 42 at 50, 10 at 100 -- is an edge however many
  # stronger ones the picture has: a step of c levels blurred is c / (2.5 sigma) at most)
  let floorHigh = 1.5 + 4.5 * float(100 - detail) / 99
  let sure = 10 + 90 * pow(float(100 - detail) / 99, 1.5)
  let ceilHigh = 0.9 * sure / (2.5 * sigma)
  let high = float32(clamp(bin.float / 4, floorHigh, ceilHigh))   # (the bin's lower edge: all in it kept)
  let low = high * 0.4'f32
  # ---- the strong ones, and the weaker ones joined to them ---------------------------------------
  let off = [1, w + 1, w, w - 1, -1, -w - 1, -w, -w + 1]
  var stack: seq[int32]
  for i in 0 ..< info.len:
    if (info[i] and fCand) != 0 and mag[i] >= high:
      info[i] = info[i] or fEdge
      stack.add int32(i)
  while stack.len > 0:
    let p = int(stack.pop())
    for d in off:
      let q = p + d
      if (info[q] and (fCand or fEdge)) == fCand and mag[q] >= low:
        info[q] = info[q] or fEdge
        stack.add int32(q)
  var edges: seq[int32]
  for i in 0 ..< info.len:
    if (info[i] and fEdge) != 0: edges.add int32(i)
  # ---- one pixel wide: a pixel its neighbours stay joined without goes (twice round) -------------
  for _ in 0 .. 1:
    var kept = 0
    for p in edges:
      let mk = nmask(info, int(p), off)
      if popcount(mk) >= 2 and ringComps[mk] == 1 and (mk and 0b0101_0101) != 0b0101_0101:
        info[p] = info[p] and not fEdge
      else:
        edges[kept] = p
        inc kept
    edges.setLen(kept)
  # ---- branch points: those touching 3 or more, each group of them one ----------------------------
  var cluster = newSeq[int32]()       # (scratch in `result.index` for the branch pixels)
  var nClusters = 0
  template deg(p: int): int = popcount(nmask(info, p, off))
  for p in edges:
    if result.index[p] >= 0 or deg(int(p)) < 3: continue
    result.index[p] = int32(nClusters)
    cluster.setLen(0)
    cluster.add p
    while cluster.len > 0:
      let q = int(cluster.pop())
      for d in off:
        let r = q + d
        if (info[r] and fEdge) != 0 and result.index[r] < 0 and deg(r) >= 3:
          result.index[r] = int32(nClusters)
          cluster.add int32(r)
    inc nClusters
  # ---- followed: from each end and branch point, then the loops ------------------------------------
  var segs: seq[Seg]
  for e in edges:
    let p = int(e)
    let mk = nmask(info, p, off)
    let dp = popcount(mk)
    if dp == 2 or dp == 0: continue
    for kk in 0 .. 7:
      if (mk and (1 shl kk)) == 0: continue
      let q = p + off[kk]
      let dq = deg(q)
      if dq == 2:
        if (info[q] and fUsed) == 0: segs.add Seg(px: walk(info, off, p, q, true))
      elif q > p and not (dp >= 3 and dq >= 3):
        segs.add Seg(px: @[int32(p), int32(q)])
  for e in edges:
    let p = int(e)
    if (info[p] and fUsed) != 0: continue
    let mk = nmask(info, p, off)
    if popcount(mk) != 2: continue
    info[p] = info[p] or fUsed
    segs.add Seg(px: walk(info, off, p, p + off[countTrailingZeroBits(mk)], false))
  for sg in segs.mitems:
    sg.a = result.index[sg.px[0]]
    sg.b = result.index[sg.px[^1]]
  for p in edges: result.index[p] = -1
  # ---- short spurs and bits dropped; the lines through a branch point left with two joined ----------
  let minLen = max(2, int(round(12.0 - detail.float / 10)))
  var alive = newSeq[bool](segs.len)
  var ends = newSeq[seq[(int32, int8)]](nClusters)
  for i, sg in segs:
    alive[i] = sg.px.len >= minLen or (sg.a >= 0 and sg.b >= 0 and sg.a != sg.b)
    if alive[i]:
      if sg.a >= 0: ends[sg.a].add (int32(i), 0'i8)
      if sg.b >= 0: ends[sg.b].add (int32(i), 1'i8)
  template through(c: int32): bool = c >= 0 and ends[c].len == 2
  template otherEnd(c: int32; mine: (int32, int8)): (int32, int8) =
    (if ends[c][0] == mine: ends[c][1] else: ends[c][0])
  var done = newSeq[bool](segs.len)
  var found: seq[seq[int32]]
  for s0 in 0 ..< segs.len:
    if not alive[s0] or done[s0]: continue
    # (back to where the line starts)
    var cur = s0
    var rev = false
    var guard = 0
    while guard <= segs.len:
      inc guard
      let c = if rev: segs[cur].b else: segs[cur].a
      if not through(c): break
      let o = otherEnd(c, (int32(cur), int8(if rev: 1 else: 0)))
      if int(o[0]) == s0:                 # (round: a loop)
        cur = s0
        rev = false
        break
      cur = int(o[0])
      rev = o[1] == 0
    # (then along it)
    var line: seq[int32]
    guard = 0
    while guard <= segs.len:
      inc guard
      done[cur] = true
      let px = segs[cur].px
      for j in 0 ..< px.len:
        let q = if rev: px[px.high - j] else: px[j]
        if line.len == 0 or line[^1] != q: line.add q
      let e = if rev: segs[cur].a else: segs[cur].b
      if not through(e): break
      let o = otherEnd(e, (int32(cur), int8(if rev: 0 else: 1)))
      if done[o[0]]: break
      cur = int(o[0])
      rev = o[1] == 1
    if line.len >= minLen: found.add line
  # ---- the points: on the edge to a fraction of a pixel, in the picture's pixels ---------------------
  # (the peak of a parabola through the strengths on either side across the edge; moved
  # from the pixel's middle only across the line the chain's pixels make there, so the
  # points stay evenly spaced along it)
  let dOff = [1, w + 1, w, 1 - w]
  let dirs = [(1.0, 0.0), (1.0, 1.0), (0.0, 1.0), (1.0, -1.0)]
  let sf = s.float
  for ci, line in found:
    var pts = newSeqOfCap[(float, float)](line.len)
    let n = line.len
    for k, e in line:
      let p = int(e)
      result.index[p] = int32(ci)
      let sec = int(info[p] and 3)
      let d = dOff[sec]
      let m0 = mag[p]
      let mm = mag[p - d]
      let mp = mag[p + d]
      let den = float(mm) - 2 * float(m0) + float(mp)
      let t = if den < -1e-6: clamp(0.5 * float(mm - mp) / den, -0.5, 0.5) else: 0.0
      var ox = t * dirs[sec][0]
      var oy = t * dirs[sec][1]
      let a = int(line[max(0, k - 2)])
      let b = int(line[min(n - 1, k + 2)])
      let tx = float(b mod w - a mod w)
      let ty = float(b div w - a div w)
      let tl = tx * tx + ty * ty
      if tl > 0.5:
        let along = (ox * tx + oy * ty) / tl
        ox -= along * tx
        oy -= along * ty
      pts.add ((float(p mod w) + 0.5 + ox) * sf, (float(p div w) + 0.5 + oy) * sf)
    result.chains.add pts

proc chainAt*(m: EdgeMap; x, y: float; radius: float): int =
  ## The chain nearest the point (`x`, `y`) of the picture, if one passes
  ## within `radius` pixels of it; -1 if none.
  result = -1
  if m == nil or m.chains.len == 0 or m.gw <= 0 or m.gh <= 0 or radius < 0: return
  let s = m.scale.float
  let fx = x / s
  let fy = y / s
  let rr = radius / s
  if fx < -rr or fy < -rr or fx > m.gw.float + rr or fy > m.gh.float + rr: return
  let cx = int(floor(fx))
  let cy = int(floor(fy))
  var best = rr * rr
  template look(px, py: int) =
    if px >= 0 and py >= 0 and px < m.gw and py < m.gh:
      let id = m.index[py * m.gw + px]
      if id >= 0:
        let dx = px.float + 0.5 - fx
        let dy = py.float + 0.5 - fy
        let d2 = dx * dx + dy * dy
        if d2 <= best and (result < 0 or d2 < best):
          best = d2
          result = int(id)
  for k in 0 .. int(ceil(rr)) + 1:
    if (k.float - 0.5) > 0 and (k.float - 0.5) * (k.float - 0.5) > best: break
    if k == 0:
      look(cx, cy)
      continue
    for px in cx - k .. cx + k:
      look(px, cy - k)
      look(px, cy + k)
    for py in cy - k + 1 .. cy + k - 1:
      look(cx - k, py)
      look(cx + k, py)

proc chainPoints*(m: EdgeMap; i: int): seq[(float, float)] =
  ## The points of chain `i` in order along its edge, in picture pixels
  ## (none for a chain that is not there).
  if m != nil and i >= 0 and i < m.chains.len: result = m.chains[i]

proc chainClosed*(m: EdgeMap; i: int): bool =
  ## Whether chain `i` goes round: its ends within about 2 pixels of each
  ## other (of the grid: 2 x `scale` of the picture).
  if m == nil or i < 0 or i >= m.chains.len: return false
  let c = m.chains[i]
  c.len >= 4 and hypot(c[0][0] - c[^1][0], c[0][1] - c[^1][1]) <= 2.5 * m.scale.float

proc nearestIndex(c: seq[(float, float)]; x, y: float): int =
  var best = Inf
  for k, q in c:
    let d = (q[0] - x) * (q[0] - x) + (q[1] - y) * (q[1] - y)
    if d < best:
      best = d
      result = k

proc chainPart*(m: EdgeMap; i: int; fromX, fromY, toX, toY: float): seq[(float, float)] =
  ## The stretch of chain `i` between its points nearest (`fromX`,
  ## `fromY`) and (`toX`, `toY`), in order from the first to the second.
  ## Of a chain that goes round, the shorter way.
  if m == nil or i < 0 or i >= m.chains.len or m.chains[i].len == 0: return
  let c = m.chains[i]
  let a = nearestIndex(c, fromX, fromY)
  let b = nearestIndex(c, toX, toY)
  if m.chainClosed(i):
    let n = c.len
    let fwd = (b - a + n) mod n
    let back = (a - b + n) mod n
    if fwd <= back:
      for k in 0 .. fwd: result.add c[(a + k) mod n]
    else:
      for k in 0 .. back: result.add c[(a - k + n) mod n]
  elif a <= b:
    result = c[a .. b]
  else:
    for k in countdown(a, b): result.add c[k]

proc simplify*(pts: seq[(float, float)]; tolerance: float): seq[(float, float)] =
  ## The fewest of `pts` that keep the line within `tolerance` pixels of
  ## them all (Douglas-Peucker); the first and last always kept.
  if pts.len <= 2: return pts
  var keep = newSeq[bool](pts.len)
  keep[0] = true
  keep[^1] = true
  var stack = @[(0, pts.high)]
  let tol = max(0.0, tolerance)
  while stack.len > 0:
    let (lo, hi) = stack.pop()
    if hi <= lo + 1: continue
    let (ax, ay) = pts[lo]
    let (bx, by) = pts[hi]
    let len = hypot(bx - ax, by - ay)
    var worst = -1.0
    var at = -1
    for k in lo + 1 ..< hi:
      let (px, py) = pts[k]
      # (from the line between the ends -- or, where they meet, from the end)
      let d = if len < 1e-9: hypot(px - ax, py - ay)
              else: abs((bx - ax) * (ay - py) - (ax - px) * (by - ay)) / len
      if d > worst:
        worst = d
        at = k
    if worst > tol:
      keep[at] = true
      stack.add (lo, at)
      stack.add (at, hi)
  for k, q in pts:
    if keep[k]: result.add q
