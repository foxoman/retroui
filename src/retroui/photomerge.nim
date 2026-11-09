## Photos put together, and photos made better from several, on the device:
## corners found and matched between pictures (with RANSAC), pictures
## aligned (moved; moved, turned and scaled; or in perspective), panoramas
## (Photomerge), stacks blended for focus, exposures fused into one (Merge
## to HDR), a sky replaced, skin smoothed and Surface Blur.
##
## ```nim
## let pano = photomerge(@[left, middle, right], amPerspective)
## let hdr = exposureFusion(@[dark, normal, bright])
## let masks = focusStackMasks(aligned)        # a layer mask for each
## ```

import std/[math, algorithm, random]
import gfx, photo, photofx, parallel

template pptr(s: seq[uint32]): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](if s.len > 0: unsafeAddr s[0] else: nil)

template fptr(s: seq[float32]): ptr UncheckedArray[float32] =
  cast[ptr UncheckedArray[float32]](if s.len > 0: unsafeAddr s[0] else: nil)

# ---- planes of floats --------------------------------------------------------------------------------------

type
  Plane = object
    ## One channel of numbers (0..1 for light).
    w, h: int
    v: seq[float32]

proc newPlane(w, h: int): Plane = Plane(w: w, h: h, v: newSeq[float32](w * h))

proc boxBlur(p: var Plane; r: int) =
  ## A box blur of radius `r` (running sums: as fast for any size).
  if r <= 0 or p.w == 0 or p.h == 0: return
  let w = p.w
  let h = p.h
  var tmp = newSeq[float32](w * h)
  let src = fptr(p.v)
  let tp = fptr(tmp)
  parallelRows(h, y):
    var s = 0'f32
    let row = y * w
    for k in -r .. r: s += src[row + clamp(k, 0, w - 1)]
    let n = float32(2 * r + 1)
    for x in 0 ..< w:
      tp[row + x] = s / n
      s += src[row + min(x + r + 1, w - 1)] - src[row + max(x - r, 0)]
  let dst = fptr(p.v)
  parallelChunks(w, lo, hi):
    for x in lo ..< hi:
      var s = 0'f32
      for k in -r .. r: s += tp[clamp(k, 0, h - 1) * w + x]
      let n = float32(2 * r + 1)
      for y in 0 ..< h:
        dst[y * w + x] = s / n
        s += tp[min(y + r + 1, h - 1) * w + x] - tp[max(y - r, 0) * w + x]

proc gaussLike(p: var Plane; sigma: float) =
  ## Three box blurs: close to a Gaussian of `sigma`.
  let r = max(0, int(round(sqrt(12.0 * sigma * sigma / 3.0 + 1.0) / 2.0 - 0.5)))
  for _ in 0 .. 2: p.boxBlur(r)

proc lumOf(p: uint32): float32 {.inline.} =
  float32(0.299 * float((p shr 16) and 255) + 0.587 * float((p shr 8) and 255) +
          0.114 * float(p and 255)) / 255'f32

proc grayPlane(im: Img; maxSide: int): (Plane, float) =
  ## The picture's light, made smaller (by averaging) so that its longer
  ## side is at most `maxSide`; and how much smaller (small / big).
  let k = min(1.0, maxSide.float / max(1, max(im.w, im.h)).float)
  let w = max(1, int(round(im.w.float * k)))
  let h = max(1, int(round(im.h.float * k)))
  var g = newPlane(w, h)
  let sp = pptr(im.px)
  let gp = fptr(g.v)
  let iw = im.w
  let ih = im.h
  parallelRows(h, y):
    let y0 = y * ih div h
    let y1 = max(y0 + 1, (y + 1) * ih div h)
    for x in 0 ..< w:
      let x0 = x * iw div w
      let x1 = max(x0 + 1, (x + 1) * iw div w)
      var s = 0'f32
      for yy in y0 ..< y1:
        for xx in x0 ..< x1: s += lumOf(sp[yy * iw + xx])
      gp[y * w + x] = s / float32((y1 - y0) * (x1 - x0))
  (g, w.float / im.w.float)

# ---- corners and what they look like ------------------------------------------------------------------

const DescSide = 8                ## a corner's look: 8 x 8 samples ...
const DescStep = 4                ## ... 4 pixels apart (a window of 32)

type
  Features* = object
    ## The corners found in a picture (in its small copy's pixels) and
    ## what is around each.
    k*: float                     ## small / full size
    w*, h*: int                   ## the full size
    xs, ys: seq[float32]
    desc: seq[float32]            ## DescSide² numbers per corner (mean 0, length 1)

proc len*(f: Features): int = f.xs.len
  ## How many corners were found.

proc sample(p: Plane; x, y: float32): float32 {.inline.} =
  let fx = clamp(x, 0, float32(p.w - 1))
  let fy = clamp(y, 0, float32(p.h - 1))
  let x0 = min(int(fx), p.w - 1)
  let y0 = min(int(fy), p.h - 1)
  let x1 = min(x0 + 1, p.w - 1)
  let y1 = min(y0 + 1, p.h - 1)
  let tx = fx - float32(x0)
  let ty = fy - float32(y0)
  let a = p.v[y0 * p.w + x0] * (1 - tx) + p.v[y0 * p.w + x1] * tx
  let b = p.v[y1 * p.w + x0] * (1 - tx) + p.v[y1 * p.w + x1] * tx
  a * (1 - ty) + b * ty

proc featuresOf*(im: Img; maxSide = 700; most = 700): Features =
  ## The corners of `im` (Harris), spread over the picture, each with the
  ## look of what is around it.
  let (g0, k) = grayPlane(im, maxSide)
  result.k = k
  result.w = im.w
  result.h = im.h
  let w = g0.w
  let h = g0.h
  if w < 48 or h < 48: return
  var g = g0
  g.boxBlur(1)
  var ixx = newPlane(w, h)
  var iyy = newPlane(w, h)
  var ixy = newPlane(w, h)
  for y in 1 ..< h - 1:
    for x in 1 ..< w - 1:
      let gx = (g.v[y * w + x + 1] - g.v[y * w + x - 1]) * 0.5'f32
      let gy = (g.v[(y + 1) * w + x] - g.v[(y - 1) * w + x]) * 0.5'f32
      ixx.v[y * w + x] = gx * gx
      iyy.v[y * w + x] = gy * gy
      ixy.v[y * w + x] = gx * gy
  for p in [addr ixx, addr iyy, addr ixy]:
    p[].boxBlur(2)
    p[].boxBlur(2)
  var r = newSeq[float32](w * h)
  var top = 0'f32
  for i in 0 ..< w * h:
    let a = ixx.v[i]
    let b = iyy.v[i]
    let c = ixy.v[i]
    r[i] = a * b - c * c - 0.04'f32 * (a + b) * (a + b)
    top = max(top, r[i])
  if top <= 0: return
  # the strongest in each cell of a grid (so they are spread out), then the
  # strongest of those
  let margin = DescSide * DescStep div 2 + 2
  let cell = max(10, min(w, h) div 14)
  var cand: seq[(float32, int, int)]
  var y = margin
  while y < h - margin:
    var x = margin
    while x < w - margin:
      var best: seq[(float32, int, int)]
      for yy in y ..< min(y + cell, h - margin):
        for xx in x ..< min(x + cell, w - margin):
          let v = r[yy * w + xx]
          if v < top * 0.0005'f32: continue
          var isMax = true
          for dy in -2 .. 2:
            for dx in -2 .. 2:
              if (dx != 0 or dy != 0) and r[(yy + dy) * w + xx + dx] > v:
                isMax = false
          if isMax: best.add (v, xx, yy)
      best.sort(proc (a, b: (float32, int, int)): int = cmp(b[0], a[0]))
      for i in 0 ..< min(4, best.len): cand.add best[i]
      x += cell
    y += cell
  cand.sort(proc (a, b: (float32, int, int)): int = cmp(b[0], a[0]))
  if cand.len > most: cand.setLen(most)
  # what is around each: a blurred 32 x 32 window, sampled 8 x 8
  var b = g0
  b.gaussLike(2.0)
  let n = DescSide * DescSide
  for (_, cx, cy) in cand:
    var d = newSeq[float32](n)
    var mean = 0'f32
    for j in 0 ..< DescSide:
      for i in 0 ..< DescSide:
        let v = b.sample(float32(cx) + (float32(i) - 3.5'f32) * DescStep,
                         float32(cy) + (float32(j) - 3.5'f32) * DescStep)
        d[j * DescSide + i] = v
        mean += v
    mean /= float32(n)
    var ss = 0'f32
    for v in d.mitems:
      v -= mean
      ss += v * v
    if ss < 1e-6: continue                      # (flat: nothing to know it by)
    let s = 1'f32 / sqrt(ss)
    for v in d.mitems: v *= s
    result.xs.add float32(cx)
    result.ys.add float32(cy)
    result.desc.add d

proc matches(a, b: Features): seq[(int, int)] =
  ## Corners of `a` and `b` that look alike: each the other's best, and
  ## clearly better than the next best.
  let n = DescSide * DescSide
  let na = a.len
  let nb = b.len
  if na == 0 or nb == 0: return
  var bestA = newSeq[int](na)
  var okA = newSeq[bool](na)
  var bestB = newSeq[int](nb)
  let ad = fptr(a.desc)
  let bd = fptr(b.desc)
  parallelChunks(na, lo, hi):
    for i in lo ..< hi:
      var d1 = 1e9'f32
      var d2 = 1e9'f32
      var bj = -1
      for j in 0 ..< nb:
        var s = 0'f32
        for t in 0 ..< n:
          let e = ad[i * n + t] - bd[j * n + t]
          s += e * e
        if s < d1:
          d2 = d1
          d1 = s
          bj = j
        elif s < d2: d2 = s
      bestA[i] = bj
      okA[i] = bj >= 0 and d1 < 0.64'f32 * d2
  parallelChunks(nb, lo, hi):
    for j in lo ..< hi:
      var d1 = 1e9'f32
      var bi = -1
      for i in 0 ..< na:
        var s = 0'f32
        for t in 0 ..< n:
          let e = ad[i * n + t] - bd[j * n + t]
          s += e * e
        if s < d1:
          d1 = s
          bi = i
      bestB[j] = bi
  for i in 0 ..< na:
    if okA[i] and bestB[bestA[i]] == i: result.add (i, bestA[i])

# ---- models: where a picture's points go in another ---------------------------------------------------

type
  Homography* = array[9, float]
    ## Where the points of one picture are in another: x' = (h0 x + h1 y +
    ## h2) / (h6 x + h7 y + h8), y' = (h3 x + h4 y + h5) / (...).
  AlignModel* = enum
    ## How one picture may be changed to lie on another (Photomerge's Layout).
    amTranslation = "Reposition"    ## moved
    amSimilarity = "Collage"        ## moved, turned and scaled
    amPerspective = "Perspective"   ## in perspective
  Match* = object
    ## How picture B lies on picture A.
    ok*: bool                       ## they were matched (else the rest means nothing)
    h*: Homography                  ## B's points (full size) to A's
    inliers*: int                   ## how many corners agree

const Identity*: Homography = [1.0, 0, 0, 0, 1, 0, 0, 0, 1]
  ## The homography that leaves every point where it is.

proc apply*(h: Homography; x, y: float): (float, float) {.inline.} =
  ## Where the point `x`, `y` goes.
  let w = h[6] * x + h[7] * y + h[8]
  let iw = if abs(w) < 1e-12: 1e12 else: 1 / w
  ((h[0] * x + h[1] * y + h[2]) * iw, (h[3] * x + h[4] * y + h[5]) * iw)

proc `*`*(a, b: Homography): Homography =
  ## `a` after `b`.
  for r in 0 .. 2:
    for c in 0 .. 2:
      result[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c]

proc inverse*(h: Homography): Homography =
  ## The homography that takes the points back (`Identity` when there is
  ## none).
  let a = h[0]; let b = h[1]; let c = h[2]
  let d = h[3]; let e = h[4]; let f = h[5]
  let g = h[6]; let k = h[7]; let i = h[8]
  let A = e * i - f * k
  let B = -(d * i - f * g)
  let C = d * k - e * g
  let det = a * A + b * B + c * C
  if abs(det) < 1e-15: return Identity
  let s = 1 / det
  [A * s, -(b * i - c * k) * s, (b * f - c * e) * s,
   B * s, (a * i - c * g) * s, -(a * f - c * d) * s,
   C * s, -(a * k - b * g) * s, (a * e - b * d) * s]

proc normalized(h: Homography): Homography =
  result = h
  if abs(h[8]) > 1e-15:
    for v in result.mitems: v /= h[8]

proc solve(m: var seq[float]; rhs: var seq[float]; n: int): bool =
  ## Solves the n x n system in place (Gauss with pivoting).
  for c in 0 ..< n:
    var p = c
    for r in c + 1 ..< n:
      if abs(m[r * n + c]) > abs(m[p * n + c]): p = r
    if abs(m[p * n + c]) < 1e-12: return false
    if p != c:
      for k in 0 ..< n: swap(m[c * n + k], m[p * n + k])
      swap(rhs[c], rhs[p])
    for r in c + 1 ..< n:
      let f = m[r * n + c] / m[c * n + c]
      if f == 0: continue
      for k in c ..< n: m[r * n + k] -= f * m[c * n + k]
      rhs[r] -= f * rhs[c]
  for c in countdown(n - 1, 0):
    var s = rhs[c]
    for k in c + 1 ..< n: s -= m[c * n + k] * rhs[k]
    rhs[c] = s / m[c * n + c]
  true

type Pt = (float, float)

proc fitModel(src, dst: openArray[Pt]; model: AlignModel; h: var Homography): bool =
  ## The model taking `src` to `dst` (least squares when there are more
  ## points than it needs).
  let n = src.len
  case model
  of amTranslation:
    if n < 1: return false
    var dx, dy = 0.0
    for i in 0 ..< n:
      dx += dst[i][0] - src[i][0]
      dy += dst[i][1] - src[i][1]
    h = [1.0, 0, dx / n.float, 0, 1, dy / n.float, 0, 0, 1]
    true
  of amSimilarity:
    if n < 2: return false
    var sx, sy, dx, dy = 0.0
    for i in 0 ..< n:
      sx += src[i][0]; sy += src[i][1]; dx += dst[i][0]; dy += dst[i][1]
    sx /= n.float; sy /= n.float; dx /= n.float; dy /= n.float
    var a, b, ss = 0.0
    for i in 0 ..< n:
      let px = src[i][0] - sx
      let py = src[i][1] - sy
      let qx = dst[i][0] - dx
      let qy = dst[i][1] - dy
      a += px * qx + py * qy
      b += px * qy - py * qx
      ss += px * px + py * py
    if ss < 1e-9: return false
    let c = a / ss
    let s = b / ss
    h = [c, -s, dx - (c * sx - s * sy), s, c, dy - (s * sx + c * sy), 0, 0, 1]
    true
  of amPerspective:
    if n < 4: return false
    # (both sets moved to their middle and scaled: a better conditioned system)
    proc norm(p: openArray[Pt]): (float, float, float) =
      var cx, cy = 0.0
      for q in p:
        cx += q[0]; cy += q[1]
      cx /= p.len.float; cy /= p.len.float
      var d = 0.0
      for q in p: d += sqrt((q[0] - cx) ^ 2 + (q[1] - cy) ^ 2)
      d /= p.len.float
      (cx, cy, if d < 1e-9: 1.0 else: sqrt(2.0) / d)
    let (scx, scy, ss) = norm(src)
    let (dcx, dcy, ds) = norm(dst)
    var m = newSeq[float](64)
    var rhs = newSeq[float](8)
    for i in 0 ..< n:
      let x = (src[i][0] - scx) * ss
      let y = (src[i][1] - scy) * ss
      let u = (dst[i][0] - dcx) * ds
      let v = (dst[i][1] - dcy) * ds
      for (row, t) in [([x, y, 1.0, 0, 0, 0, -u * x, -u * y], u), ([0.0, 0, 0, x, y, 1, -v * x, -v * y], v)]:
        for r in 0 .. 7:
          for c in 0 .. 7: m[r * 8 + c] += row[r] * row[c]
          rhs[r] += row[r] * t
    if not solve(m, rhs, 8): return false
    let hn: Homography = [rhs[0], rhs[1], rhs[2], rhs[3], rhs[4], rhs[5], rhs[6], rhs[7], 1.0]
    let tSrc: Homography = [ss, 0, -scx * ss, 0, ss, -scy * ss, 0, 0, 1]
    let tDstInv: Homography = [1 / ds, 0, dcx, 0, 1 / ds, dcy, 0, 0, 1]
    h = normalized(tDstInv * hn * tSrc)
    true

proc sane(h: Homography; w, hh: int): bool =
  ## Not folded over, squashed to nothing or blown up.
  let det = h[0] * h[4] - h[1] * h[3]
  if det < 0.05 or det > 20: return false
  for (x, y) in [(0.0, 0.0), (w.float, 0.0), (w.float, hh.float), (0.0, hh.float)]:
    if h[6] * x + h[7] * y + h[8] < 0.2: return false
  true

proc matchPair*(a, b: Features; model: AlignModel): Match =
  ## Where picture B (its features `b`) lies on picture A: corners matched,
  ## the model that most of them agree on (RANSAC), worked out again from
  ## all of those.
  let pairs = matches(a, b)
  let need = case model
             of amTranslation: 1
             of amSimilarity: 2
             of amPerspective: 4
  let minInliers = case model
                   of amTranslation: 8
                   of amSimilarity: 10
                   of amPerspective: 14
  if pairs.len < max(need, minInliers): return
  # in full size pixels
  var src, dst: seq[Pt]
  for (i, j) in pairs:
    src.add (b.xs[j].float / b.k, b.ys[j].float / b.k)
    dst.add (a.xs[i].float / a.k, a.ys[i].float / a.k)
  let th = 3.0 / min(a.k, b.k)
  var rng = initRand(7)
  var best: seq[int]
  var bestH: Homography
  let iters = case model
              of amTranslation: 200
              of amSimilarity: 400
              of amPerspective: 1500
  var s = newSeq[Pt](need)
  var d = newSeq[Pt](need)
  for _ in 0 ..< iters:
    for k in 0 ..< need:
      let t = rng.rand(pairs.high)
      s[k] = src[t]
      d[k] = dst[t]
    var h: Homography
    if not fitModel(s, d, model, h): continue
    var inl: seq[int]
    for t in 0 ..< pairs.len:
      let (x, y) = h.apply(src[t][0], src[t][1])
      if (x - dst[t][0]) ^ 2 + (y - dst[t][1]) ^ 2 < th * th: inl.add t
    if inl.len > best.len:
      best = inl
      bestH = h
  if best.len < minInliers: return
  # again from all that agree (twice: the set may grow)
  var h = bestH
  for _ in 0 .. 1:
    var s2, d2: seq[Pt]
    for t in best:
      s2.add src[t]
      d2.add dst[t]
    var h2: Homography
    if not fitModel(s2, d2, model, h2): break
    h = h2
    var inl: seq[int]
    for t in 0 ..< pairs.len:
      let (x, y) = h.apply(src[t][0], src[t][1])
      if (x - dst[t][0]) ^ 2 + (y - dst[t][1]) ^ 2 < th * th: inl.add t
    if inl.len < minInliers: break
    best = inl
  if not sane(h, b.w, b.h): return
  Match(ok: true, h: h, inliers: best.len)

proc alignAll*(feats: seq[Features]; model: AlignModel; reference = -1):
    tuple[h: seq[Homography]; ok: seq[bool]; reference: int] =
  ## Every picture placed on the reference one (the one most of the others
  ## overlap when -1): each through the picture it overlaps best, already
  ## placed. `ok` is false for one that overlaps none.
  let n = feats.len
  result.h = newSeq[Homography](n)
  result.ok = newSeq[bool](n)
  if n == 0: return
  var m = newSeq[Match](n * n)                  # m[a * n + b]: b on a
  for a in 0 ..< n:
    for b in a + 1 ..< n:
      let ab = matchPair(feats[a], feats[b], model)
      if ab.ok:
        m[a * n + b] = ab
        m[b * n + a] = Match(ok: true, h: normalized(inverse(ab.h)), inliers: ab.inliers)
  var r = reference
  if r < 0 or r >= n:
    var most = -1
    for a in 0 ..< n:
      var s = 0
      for b in 0 ..< n:
        if m[a * n + b].ok: s += m[a * n + b].inliers
      if s > most:
        most = s
        r = a
  result.reference = r
  result.h[r] = Identity
  result.ok[r] = true
  while true:
    var bp = -1
    var bu = -1
    var bi = 0
    for p in 0 ..< n:
      if not result.ok[p]: continue
      for u in 0 ..< n:
        if result.ok[u] or not m[p * n + u].ok: continue
        if m[p * n + u].inliers > bi:
          bi = m[p * n + u].inliers
          bp = p
          bu = u
    if bu < 0: break
    result.h[bu] = normalized(result.h[bp] * m[bp * n + bu].h)
    result.ok[bu] = true

# ---- warping ------------------------------------------------------------------------------------------------

proc bilinearAt(sp: ptr UncheckedArray[uint32]; w, h: int; x, y: float): uint32 {.inline.} =
  ## The picture at `x`, `y` (pixel centres at .5) read between its pixels;
  ## transparent outside.
  let fx = x - 0.5
  let fy = y - 0.5
  if fx < -1 or fy < -1 or fx > w.float or fy > h.float: return 0
  let x0 = int(floor(fx))
  let y0 = int(floor(fy))
  let tx = fx - x0.float
  let ty = fy - y0.float
  var a, r, g, b = 0.0
  for (dx, dy, wt) in [(0, 0, (1 - tx) * (1 - ty)), (1, 0, tx * (1 - ty)), (0, 1, (1 - tx) * ty), (1, 1, tx * ty)]:
    if wt <= 0: continue
    let xx = x0 + dx
    let yy = y0 + dy
    if xx < 0 or yy < 0 or xx >= w or yy >= h: continue
    let p = sp[yy * w + xx]
    let pa = float(p shr 24) * wt
    a += pa
    r += float((p shr 16) and 255) * pa
    g += float((p shr 8) and 255) * pa
    b += float(p and 255) * pa
  if a < 0.5: return 0
  (uint32(min(255.0, a + 0.5)) shl 24) or (uint32(r / a + 0.5) shl 16) or (uint32(g / a + 0.5) shl 8) or
    uint32(b / a + 0.5)

proc warp*(src: Img; h: Homography; w, hh: int; weights: ptr seq[float32] = nil): seq[uint32] =
  ## `src` placed by `h` (its points to these) on a `w` x `hh` picture,
  ## transparent where it does not reach; `weights`, when given, gets how
  ## far in from its edges each pixel is (0..1: blending panoramas).
  result = newSeq[uint32](w * hh)
  if weights != nil: weights[] = newSeq[float32](w * hh)
  let inv = inverse(h)
  let sp = pptr(src.px)
  let dp = pptr(result)
  let wp = if weights != nil: fptr(weights[]) else: nil
  let sw = src.w
  let sh = src.h
  let half = max(1.0, min(sw, sh).float / 2)
  parallelRows(hh, y):
    for x in 0 ..< w:
      let (u, v) = inv.apply(x.float + 0.5, y.float + 0.5)
      if u < -1 or v < -1 or u > sw.float + 1 or v > sh.float + 1: continue
      let p = bilinearAt(sp, sw, sh, u, v)
      dp[y * w + x] = p
      if wp != nil and (p shr 24) > 0:
        let e = min(min(u, v), min(sw.float - u, sh.float - v))
        wp[y * w + x] = float32(clamp(e / half, 0.0001, 1.0))

# ---- Photomerge -----------------------------------------------------------------------------------------------

type
  Panorama* = object
    ## Pictures placed together: a layer for each (as big as the whole,
    ## transparent outside it) and the mask that blends it into the ones
    ## under it.
    w*, h*: int                   ## the whole's size
    layers*: seq[seq[uint32]]     ## each picture placed (ARGB, `w` x `h`), bottom first
    masks*: seq[seq[uint8]]       ## (empty: not blended)
    used*: seq[int]               ## which pictures, bottom first
    left*: seq[int]               ## those that overlap none of the others

proc gainOf(a, b: seq[uint32]): float =
  ## How much brighter `a` is than `b` where both are (sampled).
  var sa, sb = 0.0
  var i = 0
  while i < a.len:
    if (a[i] shr 24) == 255 and (b[i] shr 24) == 255:
      sa += lumOf(a[i])
      sb += lumOf(b[i])
    i += 7
  if sb < 1e-3 or sa < 1e-3: 1.0 else: clamp(sa / sb, 0.6, 1.6)

proc blendMasks*(weights: seq[seq[float32]]; sharp = 4.0): seq[seq[uint8]] =
  ## Layer masks that blend layers (bottom first) by their weights: each
  ## layer shows its share of all the weights from it down.
  let n = weights.len
  if n == 0: return
  let size = weights[0].len
  result = newSeq[seq[uint8]](n)
  for k in 0 ..< n: result[k] = newSeq[uint8](size)
  var acc = newSeq[float32](size)
  for k in 0 ..< n:
    let wp = fptr(weights[k])
    let ap = fptr(acc)
    let mp = cast[ptr UncheckedArray[uint8]](addr result[k][0])
    parallelChunks(size, lo, hi):
      for i in lo ..< hi:
        let wv = pow(wp[i], float32(sharp))
        if wp[i] <= 0:
          mp[i] = 0
          continue
        ap[i] += wv
        mp[i] = uint8(clamp(int(round(255'f32 * wv / max(ap[i], 1e-12'f32))), 0, 255))

proc photomerge*(imgs: seq[Img]; model = amPerspective; blend = true; maxPixels = 120_000_000;
                 reference = -1): Panorama =
  ## File > Automate > Photomerge: the pictures (in any order) placed
  ## together by what they share; their light matched; blended at the
  ## seams (`blend`). Pictures that overlap none of the others are left out
  ## (`left`).
  var feats: seq[Features]
  for im in imgs: feats.add featuresOf(im)
  var (hs, ok, r) = alignAll(feats, model, reference)
  for i in 0 ..< imgs.len:
    if not ok[i]: result.left.add i
  # the whole: around every corner placed
  var x0, y0 = 1e18
  var x1, y1 = -1e18
  for i, im in imgs:
    if not ok[i]: continue
    for (x, y) in [(0.0, 0.0), (im.w.float, 0.0), (im.w.float, im.h.float), (0.0, im.h.float)]:
      let (u, v) = hs[i].apply(x, y)
      x0 = min(x0, u); y0 = min(y0, v); x1 = max(x1, u); y1 = max(y1, v)
  if x1 <= x0: return
  var k = 1.0
  let area = (x1 - x0) * (y1 - y0)
  if area > maxPixels.float: k = sqrt(maxPixels.float / area)
  let shift: Homography = [k, 0, -x0 * k, 0, k, -y0 * k, 0, 0, 1]
  result.w = max(1, int(ceil((x1 - x0) * k)))
  result.h = max(1, int(ceil((y1 - y0) * k)))
  # the reference at the bottom, the others in order of how they were placed
  var order = @[r]
  for i in 0 ..< imgs.len:
    if ok[i] and i != r: order.add i
  var weights: seq[seq[float32]]
  for i in order:
    var wts: seq[float32]
    result.layers.add warp(imgs[i], shift * hs[i], result.w, result.h, addr wts)
    weights.add wts
    result.used.add i
  # the light of each made like that of the ones under it
  for k in 1 ..< result.layers.len:
    var under = newSeq[uint32](result.w * result.h)
    for j in 0 ..< k:
      for t in 0 ..< under.len:
        if (result.layers[j][t] shr 24) == 255: under[t] = result.layers[j][t]
    let g = gainOf(under, result.layers[k])
    if abs(g - 1) > 0.01:
      let lp = pptr(result.layers[k])
      parallelChunks(result.layers[k].len, lo, hi):
        for t in lo ..< hi:
          let p = lp[t]
          if (p shr 24) == 0: continue
          lp[t] = (p and 0xFF000000'u32) or
                  (uint32(clamp(int(float((p shr 16) and 255) * g + 0.5), 0, 255)) shl 16) or
                  (uint32(clamp(int(float((p shr 8) and 255) * g + 0.5), 0, 255)) shl 8) or
                  uint32(clamp(int(float(p and 255) * g + 0.5), 0, 255))
  if blend: result.masks = blendMasks(weights)

proc fullRect*(p: Panorama): Rect =
  ## The biggest rectangle (nearly) that the pictures fill: to crop a
  ## panorama to.
  if p.w == 0: return
  var cov = newSeq[bool](p.w * p.h)
  for L in p.layers:
    for i in 0 ..< cov.len:
      if (L[i] shr 24) >= 250: cov[i] = true
  var r = rect(0, 0, p.w, p.h)
  # (edges taken in, a row or column at a time, from the side with the most
  # holes, until there are none)
  proc holes(r: Rect; side: int): int =
    case side
    of 0:
      for x in r.x ..< r.x + r.w:
        if not cov[r.y * p.w + x]: inc result
    of 1:
      for x in r.x ..< r.x + r.w:
        if not cov[(r.y + r.h - 1) * p.w + x]: inc result
    of 2:
      for y in r.y ..< r.y + r.h:
        if not cov[y * p.w + r.x]: inc result
    else:
      for y in r.y ..< r.y + r.h:
        if not cov[y * p.w + r.x + r.w - 1]: inc result
  while r.w > 2 and r.h > 2:
    var worst = -1
    var most = 0
    for s in 0 .. 3:
      let hcount = holes(r, s)
      let frac = hcount / (if s < 2: r.w else: r.h)
      if hcount > 0 and frac * 1000 > most.float:
        most = int(frac * 1000)
        worst = s
    if worst < 0: break
    case worst
    of 0: (inc r.y; dec r.h)
    of 1: dec r.h
    of 2: (inc r.x; dec r.w)
    else: dec r.w
  r

# ---- stacks: focus --------------------------------------------------------------------------------------------

proc focusStackMasks*(imgs: seq[Img]; radius = -1): seq[seq[uint8]] =
  ## Auto-Blend Layers, Stack Images: for pictures of the same scene (all
  ## the same size, aligned) focused at different distances, a mask for
  ## each (bottom first) showing where it is the sharpest.
  let n = imgs.len
  if n == 0: return
  let w = imgs[0].w
  let h = imgs[0].h
  let r = if radius > 0: radius else: max(2, min(w, h) div 160)
  var weights: seq[seq[float32]]
  for im in imgs:
    var g = newPlane(w, h)
    for i in 0 ..< w * h: g.v[i] = lumOf(im.px[i])
    var s = newPlane(w, h)
    let gp = fptr(g.v)
    let sp = fptr(s.v)
    parallelRows(h, y):
      if y > 0 and y < h - 1:
        for x in 1 ..< w - 1:
          let c = gp[y * w + x]
          let l = 4 * c - gp[y * w + x - 1] - gp[y * w + x + 1] - gp[(y - 1) * w + x] - gp[(y + 1) * w + x]
          sp[y * w + x] = l * l
    # (near: its own detail; far: that around it, so that flat parts go
    # with the picture that is sharp nearby)
    var broad = s
    s.boxBlur(r)
    s.boxBlur(r)
    broad.boxBlur(r * 8)
    broad.boxBlur(r * 8)
    for i in 0 ..< w * h: s.v[i] += 0.5'f32 * broad.v[i]
    weights.add s.v
  # the sharpest gets it (softly: the weights to a high power), and what
  # is flat everywhere goes to the bottom one
  for i in 0 ..< w * h:
    var top = 0'f32
    for k in 0 ..< n: top = max(top, weights[k][i])
    for k in 0 ..< n:
      weights[k][i] = if top <= 1e-7'f32: (if k == 0: 1'f32 else: 0'f32)
                      else: max(1e-6'f32, weights[k][i] / top)
  var ws: seq[Plane]
  for k in 0 ..< n:
    var p = Plane(w: w, h: h, v: weights[k])
    for v in p.v.mitems: v = pow(v, 8'f32)
    p.boxBlur(max(1, r div 2))
    ws.add p
  var acc = newSeq[float32](w * h)
  result = newSeq[seq[uint8]](n)
  for k in 0 ..< n:
    result[k] = newSeq[uint8](w * h)
    for i in 0 ..< w * h:
      let v = ws[k].v[i]
      acc[i] += v
      result[k][i] = if k == 0: 255'u8 else: uint8(clamp(int(255 * v / max(acc[i], 1e-12) + 0.5), 0, 255))

# ---- exposures fused (Merge to HDR) ---------------------------------------------------------------------------

proc down(p: Plane): Plane =
  ## Half the size, blurred first ([1 4 6 4 1] each way).
  let w = p.w
  let h = p.h
  let nw = max(1, (w + 1) div 2)
  let nh = max(1, (h + 1) div 2)
  var tmp = newPlane(nw, h)
  let sp = fptr(p.v)
  let tp = fptr(tmp.v)
  parallelRows(h, y):
    for x in 0 ..< nw:
      let c = 2 * x
      var s = 0'f32
      for (k, f) in [(-2, 1'f32), (-1, 4'f32), (0, 6'f32), (1, 4'f32), (2, 1'f32)]:
        s += f * sp[y * w + clamp(c + k, 0, w - 1)]
      tp[y * nw + x] = s / 16
  result = newPlane(nw, nh)
  let rp = fptr(result.v)
  parallelRows(nh, y):
    let c = 2 * y
    for x in 0 ..< nw:
      var s = 0'f32
      for (k, f) in [(-2, 1'f32), (-1, 4'f32), (0, 6'f32), (1, 4'f32), (2, 1'f32)]:
        s += f * tp[clamp(c + k, 0, h - 1) * nw + x]
      rp[y * nw + x] = s / 16

proc up(p: Plane; w, h: int): Plane =
  ## Made `w` x `h` again (read between its pixels).
  result = newPlane(w, h)
  let sp = fptr(p.v)
  let rp = fptr(result.v)
  let pw = p.w
  let ph = p.h
  parallelRows(h, y):
    let fy = clamp((y.float32 + 0.5'f32) * 0.5'f32 - 0.5'f32, 0, float32(ph - 1))
    let y0 = min(int(fy), ph - 1)
    let y1 = min(y0 + 1, ph - 1)
    let ty = fy - float32(y0)
    for x in 0 ..< w:
      let fx = clamp((x.float32 + 0.5'f32) * 0.5'f32 - 0.5'f32, 0, float32(pw - 1))
      let x0 = min(int(fx), pw - 1)
      let x1 = min(x0 + 1, pw - 1)
      let tx = fx - float32(x0)
      let a = sp[y0 * pw + x0] * (1 - tx) + sp[y0 * pw + x1] * tx
      let b = sp[y1 * pw + x0] * (1 - tx) + sp[y1 * pw + x1] * tx
      rp[y * w + x] = a * (1 - ty) + b * ty

proc fusionWeight(im: Img; contrast, saturation, exposure: float): Plane =
  ## How much each pixel of a picture is worth in the fused one: where it
  ## has detail, color and is well exposed.
  let w = im.w
  let h = im.h
  result = newPlane(w, h)
  let sp = pptr(im.px)
  let rp = fptr(result.v)
  parallelRows(h, y):
    for x in 0 ..< w:
      let p = sp[y * w + x]
      let r = float((p shr 16) and 255) / 255
      let g = float((p shr 8) and 255) / 255
      let b = float(p and 255) / 255
      let l = 0.299 * r + 0.587 * g + 0.114 * b
      var c = 0.0
      if x > 0 and y > 0 and x < w - 1 and y < h - 1:
        c = abs(4 * l - lumOf(sp[y * w + x - 1]) - lumOf(sp[y * w + x + 1]) -
                lumOf(sp[(y - 1) * w + x]) - lumOf(sp[(y + 1) * w + x]))
      let m = (r + g + b) / 3
      let s = sqrt(((r - m) ^ 2 + (g - m) ^ 2 + (b - m) ^ 2) / 3)
      let e = exp(-((r - 0.5) ^ 2) / 0.08) * exp(-((g - 0.5) ^ 2) / 0.08) * exp(-((b - 0.5) ^ 2) / 0.08)
      rp[y * w + x] = float32(pow(c + 0.002, contrast) * pow(s + 0.002, saturation) * pow(e + 1e-6, exposure))

proc exposureFusion*(imgs: seq[Img]; contrast = 1.0; saturation = 1.0; exposure = 1.0): Img =
  ## Merge to HDR: pictures of the same scene at different exposures (the
  ## same size, aligned) made into one with the detail of all of them --
  ## each part from those where it is well exposed, has detail and color
  ## (blended band by band, so there are no seams).
  let n = imgs.len
  if n == 0: return
  let w = imgs[0].w
  let h = imgs[0].h
  result = newImg(w, h)
  if n == 1:
    result.px = imgs[0].px
    return
  var levels = 1
  while levels < 9 and min(w, h) shr (levels + 2) >= 4: inc levels
  # the weights' sum (to make them add up to 1)
  var total = newPlane(w, h)
  for im in imgs:
    let wt = fusionWeight(im, contrast, saturation, exposure)
    for i in 0 ..< w * h: total.v[i] += wt.v[i]
  var acc: array[3, seq[Plane]]
  for c in 0 .. 2:
    acc[c] = newSeq[Plane](levels)
  for k, im in imgs:
    var wt = fusionWeight(im, contrast, saturation, exposure)
    for i in 0 ..< w * h: wt.v[i] = wt.v[i] / max(total.v[i], 1e-12'f32)
    # the weights' Gaussian pyramid
    var gw = @[wt]
    for l in 1 ..< levels: gw.add down(gw[^1])
    for c in 0 .. 2:
      var ch = newPlane(w, h)
      let sh = 16 - 8 * c
      for i in 0 ..< w * h: ch.v[i] = float32((im.px[i] shr sh) and 255) / 255
      # its Laplacian pyramid, weighed, added
      var g = ch
      for l in 0 ..< levels:
        var band: Plane
        var next: Plane
        if l < levels - 1:
          next = down(g)
          let u = up(next, g.w, g.h)
          band = g
          for i in 0 ..< band.v.len: band.v[i] -= u.v[i]
        else: band = g
        if acc[c][l].v.len == 0: acc[c][l] = newPlane(band.w, band.h)
        let ap = fptr(acc[c][l].v)
        let bp = fptr(band.v)
        let wp = fptr(gw[l].v)
        parallelChunks(band.v.len, lo, hi):
          for i in lo ..< hi: ap[i] += bp[i] * wp[i]
        g = next
  # put back together
  for c in 0 .. 2:
    var g = acc[c][levels - 1]
    for l in countdown(levels - 2, 0):
      let u = up(g, acc[c][l].w, acc[c][l].h)
      g = acc[c][l]
      for i in 0 ..< g.v.len: g.v[i] += u.v[i]
    let sh = 16 - 8 * c
    for i in 0 ..< w * h:
      result.px[i] = result.px[i] or (uint32(clamp(int(g.v[i] * 255 + 0.5), 0, 255)) shl sh)
  for p in result.px.mitems: p = p or 0xFF000000'u32

# ---- Surface Blur, Skin Smoothing -------------------------------------------------------------------------

proc guided(p: Plane; r: int; eps: float32): Plane =
  ## The picture smoothed but for its edges (a guided filter guided by
  ## itself): flat parts are blurred over `r`, steps bigger than about
  ## sqrt(`eps`) kept.
  var mean = p
  mean.boxBlur(r)
  var sq = newPlane(p.w, p.h)
  for i in 0 ..< sq.v.len: sq.v[i] = p.v[i] * p.v[i]
  sq.boxBlur(r)
  var a = newPlane(p.w, p.h)
  var b = newPlane(p.w, p.h)
  for i in 0 ..< a.v.len:
    let m = mean.v[i]
    let v = max(0'f32, sq.v[i] - m * m)
    a.v[i] = v / (v + eps)
    b.v[i] = m - a.v[i] * m
  a.boxBlur(r)
  b.boxBlur(r)
  result = newPlane(p.w, p.h)
  for i in 0 ..< result.v.len: result.v[i] = a.v[i] * p.v[i] + b.v[i]

proc surfaceBlurImg*(src: Img; radius: int; threshold: int): Img =
  ## Surface Blur: smooth what is smooth, keep the edges (steps of more than
  ## about `threshold` levels).
  result = newImg(src.w, src.h)
  let n = src.w * src.h
  let eps = float32((max(1, threshold).float / 255) ^ 2)
  for c in 0 .. 3:
    let sh = 24 - 8 * c
    var p = newPlane(src.w, src.h)
    for i in 0 ..< n: p.v[i] = float32((src.px[i] shr sh) and 255) / 255
    let q = if c == 0: p else: guided(p, max(1, radius), eps)
    for i in 0 ..< n:
      result.px[i] = result.px[i] or (uint32(clamp(int(q.v[i] * 255 + 0.5), 0, 255)) shl sh)

proc surfaceBlur*(radius: int; threshold: int): FilterFn =
  ## Filter > Blur > Surface Blur.
  result = proc (src: Img; inner: Rect): Img = surfaceBlurImg(src, radius, threshold)

proc skinProbability*(im: Img): seq[uint8] =
  ## How much each pixel looks like skin (0..255): its color (in YCbCr)
  ## near that of skin of any tone, softly.
  result = newSeq[uint8](im.w * im.h)
  let sp = pptr(im.px)
  let rp = cast[ptr UncheckedArray[uint8]](if result.len > 0: addr result[0] else: nil)
  parallelChunks(im.px.len, lo, hi):
    for i in lo ..< hi:
      let p = sp[i]
      let r = float((p shr 16) and 255)
      let g = float((p shr 8) and 255)
      let b = float(p and 255)
      let y = 0.299 * r + 0.587 * g + 0.114 * b
      let cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b
      let cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b
      # (an ellipse around skin's Cb, Cr; soft at its edge; not too dark)
      let u = (cb - 110) / 18
      let v = (cr - 152) / 16
      let d = u * u + v * v
      var s = if d <= 1: 1.0 elif d < 2.5: (2.5 - d) / 1.5 else: 0.0
      if y < 35: s *= max(0.0, (y - 15) / 20)
      rp[i] = uint8(clamp(int(s * 255 + 0.5), 0, 255))

proc skinSmoothingImg*(src: Img; blur, smoothness: int): Img =
  ## Skin Smoothing: the skin made smooth -- its blemishes and shine
  ## evened -- keeping its fine texture, the eyes, hair and edges sharp.
  let w = src.w
  let h = src.h
  var mask = skinProbability(src)
  blurMask(mask, w, h, max(1.5, blur.float / 2))
  let smooth = surfaceBlurImg(src, max(1, blur), 22)
  var fine = src
  # (the finest texture, put back a little: skin, not plastic)
  var lp = newPlane(w, h)
  for i in 0 ..< w * h: lp.v[i] = lumOf(src.px[i])
  var lb = lp
  lb.boxBlur(1)
  let k = clamp(smoothness, 0, 100).float / 100
  result = newImg(w, h)
  for i in 0 ..< w * h:
    let m = mask[i].float / 255 * k
    let p = src.px[i]
    if m <= 0.002:
      result.px[i] = p
      continue
    let s = smooth.px[i]
    let detail = (lp.v[i] - lb.v[i]).float * 255 * 0.45
    var o = p and 0xFF000000'u32
    for sh in [16, 8, 0]:
      let a = float((p shr sh) and 255)
      let b = float((s shr sh) and 255) + detail
      o = o or (uint32(clamp(int(a + (b - a) * m + 0.5), 0, 255)) shl sh)
    result.px[i] = o
  discard fine

proc skinSmoothing*(blur, smoothness: int): FilterFn =
  ## Filter > Retouch > Skin Smoothing.
  result = proc (src: Img; inner: Rect): Img = skinSmoothingImg(src, blur, smoothness)

# ---- Sky Replacement ------------------------------------------------------------------------------------------

type SkyKind* = enum
  ## The skies there are to put in.
  skBlue = "Blue Sky", skClouds = "Blue Sky with Clouds", skDramatic = "Dramatic Clouds",
  skSunset = "Sunset", skDusk = "Dusk", skOvercast = "Overcast", skNight = "Starry Night"

proc hashNoise(x, y, seed: int): float {.inline.} =
  # (in 32 bits, wrapping: the same on every system)
  var h = cast[uint32](x) * 374761393'u32 + cast[uint32](y) * 668265263'u32 +
          cast[uint32](seed) * 2147483647'u32
  h = (h xor (h shr 13)) * 1274126177'u32
  h = h xor (h shr 16)
  float(h and 0xFFFFFF) / float(0xFFFFFF)

proc valueNoise(x, y: float; seed: int): float =
  let xi = int(floor(x))
  let yi = int(floor(y))
  let tx = x - xi.float
  let ty = y - yi.float
  let sx = tx * tx * (3 - 2 * tx)
  let sy = ty * ty * (3 - 2 * ty)
  let a = hashNoise(xi, yi, seed)
  let b = hashNoise(xi + 1, yi, seed)
  let c = hashNoise(xi, yi + 1, seed)
  let d = hashNoise(xi + 1, yi + 1, seed)
  (a * (1 - sx) + b * sx) * (1 - sy) + (c * (1 - sx) + d * sx) * sy

proc fbm(x, y: float; seed, octaves: int): float =
  var amp = 0.5
  var f = 1.0
  for o in 0 ..< octaves:
    result += amp * valueNoise(x * f, y * f, seed + o * 31)
    amp *= 0.5
    f *= 2.03

proc makeSky*(kind: SkyKind; w, h: int; seed = 1): Img =
  ## A sky, `w` x `h` (its horizon at the bottom), painted.
  result = newImg(w, h)
  type C3 = (float, float, float)
  let (top, bottom, cloudLight, cloudShade, cover): (C3, C3, C3, C3, float) = case kind
    of skBlue: ((40.0, 95.0, 185.0), (165.0, 200.0, 235.0), (255.0, 255.0, 255.0), (200.0, 210.0, 225.0), 0.0)
    of skClouds: ((45.0, 105.0, 190.0), (170.0, 205.0, 238.0), (255.0, 255.0, 255.0), (190.0, 200.0, 215.0), 0.45)
    of skDramatic: ((30.0, 55.0, 95.0), (150.0, 165.0, 185.0), (240.0, 240.0, 240.0), (80.0, 88.0, 100.0), 0.7)
    of skSunset: ((70.0, 60.0, 130.0), (255.0, 150.0, 70.0), (255.0, 205.0, 160.0), (150.0, 80.0, 90.0), 0.4)
    of skDusk: ((15.0, 25.0, 70.0), (230.0, 120.0, 90.0), (120.0, 90.0, 120.0), (40.0, 35.0, 70.0), 0.3)
    of skOvercast: ((150.0, 155.0, 165.0), (205.0, 208.0, 212.0), (230.0, 230.0, 232.0), (130.0, 133.0, 140.0), 0.95)
    of skNight: ((5.0, 8.0, 25.0), (25.0, 40.0, 80.0), (60.0, 65.0, 90.0), (10.0, 12.0, 25.0), 0.15)
  let rp = pptr(result.px)
  let scale = 3.2 / max(w, 1).float
  parallelRows(h, y):
    let t = y.float / max(1, h - 1).float
    let tt = pow(t, 1.6)
    for x in 0 ..< w:
      var r = top[0] + (bottom[0] - top[0]) * tt
      var g = top[1] + (bottom[1] - top[1]) * tt
      var b = top[2] + (bottom[2] - top[2]) * tt
      if cover > 0:
        # clouds: flatter and smaller towards the horizon
        let sy = scale * (1 + 2.5 * t)
        let n = fbm(x.float * scale, y.float * sy * 2.2, seed, 6)
        let c = clamp((n - (0.62 - cover * 0.32)) / 0.22, 0.0, 1.0)
        if c > 0:
          let shade = clamp((fbm(x.float * scale * 1.7 + 9, y.float * sy * 3 + 4, seed + 7, 4) - 0.35) * 2, 0.0, 1.0)
          let cr = cloudLight[0] + (cloudShade[0] - cloudLight[0]) * shade
          let cg = cloudLight[1] + (cloudShade[1] - cloudLight[1]) * shade
          let cb = cloudLight[2] + (cloudShade[2] - cloudLight[2]) * shade
          r += (cr - r) * c
          g += (cg - g) * c
          b += (cb - b) * c
      if kind == skNight:
        let s = hashNoise(x, y, seed + 99)
        if s > 0.9985 and t < 0.85:
          let v = (s - 0.9985) / 0.0015 * 255 * (1 - t)
          r += v; g += v; b += v
      rp[y * w + x] = argb(255, clamp(int(r), 0, 255), clamp(int(g), 0, 255), clamp(int(b), 0, 255))

proc skyHorizon*(mask: seq[uint8]; w, h: int): int =
  ## How far down the sky reaches (where 98 % of it is above).
  var rows = newSeq[int](h)
  var total = 0
  for y in 0 ..< h:
    for x in 0 ..< w:
      if mask[y * w + x] >= 128: inc rows[y]
    total += rows[y]
  if total == 0: return h div 2
  var s = 0
  for y in 0 ..< h:
    s += rows[y]
    if s.float >= total.float * 0.98: return y + 1
  h

proc shiftEdge*(mask: var seq[uint8]; w, h: int; by: int) =
  ## The mask's edge moved out (`by` > 0) or in, by so many pixels.
  if by == 0: return
  var m = mask
  blurMask(m, w, h, abs(by).float)
  # (blurred, then cut at a level other than half: the edge moves)
  let lv = if by > 0: 40 else: 215
  for i in 0 ..< m.len:
    let v = m[i].int
    mask[i] = if v >= lv: 255'u8 else: uint8(v * 255 div max(1, lv))

proc placeSky*(sky: Img; w, h, horizon: int; scale = 1.0; flip = false; dx = 0.0): Img =
  ## The sky as big as the photo, its bottom a little below the horizon,
  ## `scale` times as big (more of it beyond the photo's edges), moved
  ## across by `dx` (-1..1).
  result = newImg(w, h)
  if sky.w == 0 or sky.h == 0: return
  let reach = max(1, min(h, horizon + h div 12))
  let k = max(w.float / sky.w.float, reach.float / sky.h.float) * max(0.2, scale)
  let sw = sky.w.float * k
  let sh = sky.h.float * k
  let ox = (w.float - sw) / 2 + dx * max(0.0, (sw - w.float) / 2)
  let oy = reach.float - sh
  let sp = pptr(sky.px)
  let rp = pptr(result.px)
  parallelRows(h, y):
    for x in 0 ..< w:
      var u = (x.float + 0.5 - ox) / k
      let v = clamp((y.float + 0.5 - oy) / k, 0.5, sky.h.float - 0.5)
      if flip: u = sky.w.float - u
      u = clamp(u, 0.5, sky.w.float - 0.5)
      rp[y * w + x] = bilinearAt(sp, sky.w, sky.h, u, v) or 0xFF000000'u32

proc adjustSky*(sky: var Img; brightness, temperature: int) =
  ## The sky lighter or darker (-100..100) and warmer or cooler (-100..100).
  let b = brightness.float / 100
  let t = temperature.float / 100
  for p in sky.px.mitems:
    var r = float((p shr 16) and 255)
    var g = float((p shr 8) and 255)
    var bl = float(p and 255)
    if b >= 0:
      r += (255 - r) * b * 0.6; g += (255 - g) * b * 0.6; bl += (255 - bl) * b * 0.6
    else:
      r *= 1 + b * 0.7; g *= 1 + b * 0.7; bl *= 1 + b * 0.7
    r *= 1 + t * 0.18
    bl *= 1 - t * 0.18
    p = argb(255, clamp(int(r), 0, 255), clamp(int(g), 0, 255), clamp(int(bl), 0, 255))

proc skyLight*(sky: Img; mask: seq[uint8]; horizon: int): uint32 =
  ## The color of the light the sky gives (its lower part, near the
  ## horizon): for the foreground.
  var r, g, b, n = 0.0
  let y0 = max(0, horizon - max(4, horizon div 3))
  for y in y0 ..< min(horizon, sky.h):
    for x in countup(0, sky.w - 1, 3):
      let i = y * sky.w + x
      if i < mask.len and mask[i] < 128: continue
      let p = sky.px[i]
      r += float((p shr 16) and 255); g += float((p shr 8) and 255); b += float(p and 255)
      n += 1
  if n == 0: return 0xFF808080'u32
  argb(255, int(r / n), int(g / n), int(b / n))
