## Smart tools, worked out on the device (no network, no big models):
## Content-Aware Fill (what is selected made again from what is around
## it), healing (a texture brought in with the light and color of where it
## goes), red eye, Select Subject and Select Sky, Content-Aware Scale and
## enlarging with the detail kept.
##
## ```nim
## let filled = contentAwareFill(img, hole)            # hole: 0..255 per pixel
## let healed = heal(dst, src, mask)                   # src's texture, dst's light
## let sel = selectSubject(img)                        # 0..255 per pixel
## ```

import std/[math, algorithm]
import gfx, photo, photofx, photopaint, photodevelop, parallel

template pptr(s: seq[uint32]): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](if s.len > 0: unsafeAddr s[0] else: nil)

template fptr(s: seq[float32]): ptr UncheckedArray[float32] =
  cast[ptr UncheckedArray[float32]](if s.len > 0: unsafeAddr s[0] else: nil)

template iptr(s: seq[int32]): ptr UncheckedArray[int32] =
  cast[ptr UncheckedArray[int32]](if s.len > 0: unsafeAddr s[0] else: nil)

template bptr(s: seq[bool]): ptr UncheckedArray[bool] =
  cast[ptr UncheckedArray[bool]](if s.len > 0: unsafeAddr s[0] else: nil)

proc bounds(mask: openArray[uint8]; w, h: int): Rect =
  ## The rectangle around what is not 0.
  var x0 = w
  var y0 = h
  var x1 = -1
  var y1 = -1
  for y in 0 ..< h:
    for x in 0 ..< w:
      if mask[y * w + x] != 0:
        x0 = min(x0, x); x1 = max(x1, x)
        y0 = min(y0, y); y1 = max(y1, y)
  if x1 < 0: rect(0, 0, 0, 0) else: rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)

# ---- the membrane: smooth numbers inside from those around ------------------------------------------------

{.push boundChecks: off, overflowChecks: off.}

proc relax(v: ptr UncheckedArray[float32]; fixed: ptr UncheckedArray[bool]; w, h, iters: int) =
  ## Gauss-Seidel (over-relaxed) on the Laplace equation: each pixel not
  ## fixed becomes the mean of its four neighbours. `v`: 3 numbers a pixel.
  const omega = 1.85'f32
  for it in 0 ..< iters:
    for y in 0 ..< h:
      for x in 0 ..< w:
        let i = y * w + x
        if fixed[i]: continue
        var n = 0'f32
        var s0, s1, s2 = 0'f32
        if x > 0:
          s0 += v[(i - 1) * 3]; s1 += v[(i - 1) * 3 + 1]; s2 += v[(i - 1) * 3 + 2]; n += 1
        if x + 1 < w:
          s0 += v[(i + 1) * 3]; s1 += v[(i + 1) * 3 + 1]; s2 += v[(i + 1) * 3 + 2]; n += 1
        if y > 0:
          s0 += v[(i - w) * 3]; s1 += v[(i - w) * 3 + 1]; s2 += v[(i - w) * 3 + 2]; n += 1
        if y + 1 < h:
          s0 += v[(i + w) * 3]; s1 += v[(i + w) * 3 + 1]; s2 += v[(i + w) * 3 + 2]; n += 1
        if n == 0: continue
        v[i * 3] += omega * (s0 / n - v[i * 3])
        v[i * 3 + 1] += omega * (s1 / n - v[i * 3 + 1])
        v[i * 3 + 2] += omega * (s2 / n - v[i * 3 + 2])

{.pop.}

proc membrane(v: var seq[float32]; fixed: seq[bool]; w, h: int) =
  ## The pixels not `fixed` given the smoothest values that meet the fixed
  ## ones (a harmonic membrane), worked out from coarse to fine.
  if w <= 0 or h <= 0: return
  if w * h > 48 * 48 and w > 4 and h > 4:
    let cw = (w + 1) div 2
    let ch = (h + 1) div 2
    var cv = newSeq[float32](cw * ch * 3)
    var cf = newSeq[bool](cw * ch)
    for y in 0 ..< ch:
      for x in 0 ..< cw:
        var n = 0
        var s: array[3, float32]
        for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)]:
          let fx = 2 * x + dx
          let fy = 2 * y + dy
          if fx < w and fy < h and fixed[fy * w + fx]:
            for c in 0 .. 2: s[c] += v[(fy * w + fx) * 3 + c]
            inc n
        if n > 0:
          cf[y * cw + x] = true
          for c in 0 .. 2: cv[(y * cw + x) * 3 + c] = s[c] / n.float32
    membrane(cv, cf, cw, ch)
    # the coarse answer, as the start of the fine one
    for y in 0 ..< h:
      for x in 0 ..< w:
        let i = y * w + x
        if fixed[i]: continue
        let sx = clamp((x.float32 - 0.5'f32) / 2, 0, float32(cw - 1))
        let sy = clamp((y.float32 - 0.5'f32) / 2, 0, float32(ch - 1))
        let x0 = min(int(sx), cw - 1)
        let y0 = min(int(sy), ch - 1)
        let x1 = min(x0 + 1, cw - 1)
        let y1 = min(y0 + 1, ch - 1)
        let fx = sx - x0.float32
        let fy = sy - y0.float32
        for c in 0 .. 2:
          let a = cv[(y0 * cw + x0) * 3 + c] + (cv[(y0 * cw + x1) * 3 + c] - cv[(y0 * cw + x0) * 3 + c]) * fx
          let b = cv[(y1 * cw + x0) * 3 + c] + (cv[(y1 * cw + x1) * 3 + c] - cv[(y1 * cw + x0) * 3 + c]) * fx
          v[i * 3 + c] = a + (b - a) * fy
    relax(fptr(v), bptr(fixed), w, h, 24)
  else:
    relax(fptr(v), bptr(fixed), w, h, 400)

proc heal*(dst, src: Img; mask: openArray[uint8]): Img =
  ## Healing: inside `mask` (0..255, `dst`'s size), the texture of `src`
  ## (aligned with `dst`) with the light and color of `dst` around it, so
  ## it fits in without a seam (`src` plus the smooth difference that
  ## makes it meet `dst` at the mask's edge).
  result = dst
  let w = dst.w
  let h = dst.h
  if w <= 0 or h <= 0 or src.w != w or src.h != h or mask.len < w * h: return
  let r = bounds(mask, w, h)
  if r.w <= 0: return
  # (a pixel more each side: the edge the membrane meets)
  let x0 = max(0, r.x - 2)
  let y0 = max(0, r.y - 2)
  let bw = min(w, r.x + r.w + 2) - x0
  let bh = min(h, r.y + r.h + 2) - y0
  var v = newSeq[float32](bw * bh * 3)
  var fixed = newSeq[bool](bw * bh)
  for y in 0 ..< bh:
    for x in 0 ..< bw:
      let i = (y0 + y) * w + x0 + x
      let j = y * bw + x
      fixed[j] = mask[i] == 0
      if fixed[j]:
        let a = dst.px[i]
        let b = src.px[i]
        v[j * 3] = float32(rOf(a) - rOf(b))
        v[j * 3 + 1] = float32(gOf(a) - gOf(b))
        v[j * 3 + 2] = float32(bOf(a) - bOf(b))
  membrane(v, fixed, bw, bh)
  for y in 0 ..< bh:
    for x in 0 ..< bw:
      let i = (y0 + y) * w + x0 + x
      let m = int(mask[i])
      if m == 0: continue
      let j = y * bw + x
      let s = src.px[i]
      let hr = clamp(int(round(rOf(s).float32 + v[j * 3])), 0, 255)
      let hg = clamp(int(round(gOf(s).float32 + v[j * 3 + 1])), 0, 255)
      let hb = clamp(int(round(bOf(s).float32 + v[j * 3 + 2])), 0, 255)
      let d = dst.px[i]
      result.px[i] = argb(aOf(d), rOf(d) + (hr - rOf(d)) * m div 255, gOf(d) + (hg - gOf(d)) * m div 255,
                          bOf(d) + (hb - bOf(d)) * m div 255)

# ---- Content-Aware Fill (PatchMatch, coarse to fine) ------------------------------------------------------

const
  PR = 3                           # patches 7 x 7

type CafLevel = object
  w, h: int
  px: seq[uint32]
  hole: seq[bool]
  valid: seq[bool]                 # a patch around this pixel is all known (a source)
  sources: seq[int32]
  targets: seq[int32]              # the pixels whose patch touches the hole
  nnf: seq[int32]                  # per pixel: the source patch matched (-1: none)
  cost: seq[int32]

proc countIn(sum: seq[int32]; w, h, x0, y0, x1, y1: int): int32 {.inline.} =
  ## How many in [x0, x1) x [y0, y1), from the summed table (w+1) x (h+1).
  let W = w + 1
  sum[y1 * W + x1] - sum[y0 * W + x1] - sum[y1 * W + x0] + sum[y0 * W + x0]

proc setup(L: var CafLevel) =
  let w = L.w
  let h = L.h
  let W = w + 1
  var sum = newSeq[int32](W * (h + 1))
  for y in 0 ..< h:
    var row = 0'i32
    for x in 0 ..< w:
      if L.hole[y * w + x]: inc row
      sum[(y + 1) * W + x + 1] = sum[y * W + x + 1] + row
  L.valid = newSeq[bool](w * h)
  L.sources.setLen(0)
  L.targets.setLen(0)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      if x >= PR and y >= PR and x + PR < w and y + PR < h and
         countIn(sum, w, h, x - PR, y - PR, x + PR + 1, y + PR + 1) == 0:
        L.valid[i] = true
        L.sources.add int32(i)
      if countIn(sum, w, h, max(0, x - PR), max(0, y - PR), min(w, x + PR + 1), min(h, y + PR + 1)) > 0:
        L.targets.add int32(i)
  L.nnf = newSeq[int32](w * h)
  for v in L.nnf.mitems: v = -1
  L.cost = newSeq[int32](w * h)

{.push boundChecks: off, overflowChecks: off.}

proc patchDist(px: ptr UncheckedArray[uint32]; w, h, t, s: int; best: int32): int32 =
  ## The difference of the patches around `t` and `s` (squared, summed),
  ## stopping once it passes `best`.
  let tx = t mod w
  let ty = t div w
  let sx = s mod w
  let sy = s div w
  var sum = 0'i32
  for dy in -PR .. PR:
    let y = ty + dy
    if y < 0 or y >= h: continue
    let trow = y * w
    let srow = (sy + dy) * w
    for dx in -PR .. PR:
      let x = tx + dx
      if x < 0 or x >= w: continue
      let a = px[trow + x]
      let b = px[srow + sx + dx]
      let dr = int32((a shr 16) and 255) - int32((b shr 16) and 255)
      let dg = int32((a shr 8) and 255) - int32((b shr 8) and 255)
      let db = int32(a and 255) - int32(b and 255)
      sum += dr * dr + dg * dg + db * db
    if sum >= best: return sum
  sum

{.pop.}

proc costs(L: var CafLevel) =
  let px = pptr(L.px)
  let nnf = iptr(L.nnf)
  let cost = iptr(L.cost)
  let tg = iptr(L.targets)
  let w = L.w
  let h = L.h
  parallelFor(L.targets.len, proc (lo, hi: int) =
    for k in lo ..< hi:
      let t = int(tg[k])
      cost[t] = patchDist(px, w, h, t, int(nnf[t]), high(int32)), grain = 256)

proc search(L: var CafLevel; iter: int; seed: int) =
  ## One PatchMatch pass: each target tries its neighbours' matches moved
  ## along, then matches at random ever nearer to its own.
  let px = pptr(L.px)
  let nnf = iptr(L.nnf)
  let cost = iptr(L.cost)
  let valid = bptr(L.valid)
  let tg = iptr(L.targets)
  let w = L.w
  let h = L.h
  let n = L.targets.len
  let back = (iter and 1) == 1
  let pieces = max(1, min(n div 64, threadCount() * 4))
  parallelFor(pieces, proc (lo, hi: int) =
    for piece in lo ..< hi:
      var rng = uint32(seed * 7919 + iter * 104729 + piece * 15485863) or 1
      let a = n * piece div pieces
      let b = n * (piece + 1) div pieces
      for kk in 0 ..< b - a:
        let k = if back: b - 1 - kk else: a + kk
        let t = int(tg[k])
        let tx = t mod w
        let ty = t div w
        var best = cost[t]
        var bs = int(nnf[t])
        # the neighbours' matches, moved along
        for (nx, ny) in (if back: [(tx + 1, ty), (tx, ty + 1)] else: [(tx - 1, ty), (tx, ty - 1)]):
          if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
          let m = int(nnf[ny * w + nx])
          if m < 0: continue
          let cx = m mod w + (tx - nx)
          let cy = m div w + (ty - ny)
          if cx < 0 or cy < 0 or cx >= w or cy >= h: continue
          let c = cy * w + cx
          if c == bs or not valid[c]: continue
          # (a match that goes on from the neighbour's counts a little better:
          # bigger pieces copied whole, fewer seams)
          let d = patchDist(px, w, h, t, c, best + best div 12) * 12 div 13
          if d < best:
            best = d
            bs = c
        # at random, nearer and nearer
        var rad = max(w, h)
        while rad >= 1:
          rng = rng xor (rng shl 13); rng = rng xor (rng shr 17); rng = rng xor (rng shl 5)
          let rx = int(rng mod uint32(2 * rad + 1)) - rad
          rng = rng xor (rng shl 13); rng = rng xor (rng shr 17); rng = rng xor (rng shl 5)
          let ry = int(rng mod uint32(2 * rad + 1)) - rad
          let cx = clamp(bs mod w + rx, 0, w - 1)
          let cy = clamp(bs div w + ry, 0, h - 1)
          let c = cy * w + cx
          if valid[c] and c != bs:
            let d = patchDist(px, w, h, t, c, best)
            if d < best:
              best = d
              bs = c
          rad = rad div 2
        nnf[t] = int32(bs)
        cost[t] = best)

proc vote(L: var CafLevel; sharp = 1.0) =
  ## Each hole pixel: the mean of what the patches over it say (the closer
  ## matches count more).
  let n = L.targets.len
  if n == 0: return
  # (how close a match is, against the usual)
  var sample: seq[int32]
  let step = max(1, n div 2000)
  var k = 0
  while k < n:
    sample.add L.cost[L.targets[k]]
    k += step
  sample.sort()
  let s2 = max(1.0, sample[sample.len * 3 div 4].float) / sharp
  let px = pptr(L.px)
  let nnf = iptr(L.nnf)
  let cost = iptr(L.cost)
  let hole = bptr(L.hole)
  let w = L.w
  let h = L.h
  var o = L.px
  let op = pptr(o)
  parallelRows(h, y):
    for x in 0 ..< w:
      let p = y * w + x
      if not hole[p]: continue
      var sr, sg, sb, sw = 0.0
      for dy in -PR .. PR:
        let ty = y - dy
        if ty < 0 or ty >= h: continue
        for dx in -PR .. PR:
          let tx = x - dx
          if tx < 0 or tx >= w: continue
          let t = ty * w + tx
          let m = int(nnf[t])
          if m < 0: continue
          let q = (m div w + dy) * w + m mod w + dx
          let c = px[q]
          let wt = exp(-cost[t].float / (2 * s2))
          sr += float((c shr 16) and 255) * wt
          sg += float((c shr 8) and 255) * wt
          sb += float(c and 255) * wt
          sw += wt
      if sw > 0:
        op[p] = 0xFF000000'u32 or (uint32(sr / sw + 0.5) shl 16) or (uint32(sg / sw + 0.5) shl 8) or
                uint32(sb / sw + 0.5)
  L.px = move o

proc diffuse(L: var CafLevel) =
  ## The hole filled from its edge inward, each pixel the mean of the known
  ## ones next to it (the start of the coarsest level).
  let w = L.w
  let h = L.h
  var known = newSeq[bool](w * h)
  for i in 0 ..< w * h: known[i] = not L.hole[i]
  var left = 0
  for v in L.hole:
    if v: inc left
  while left > 0:
    var next: seq[(int, uint32)]
    for y in 0 ..< h:
      for x in 0 ..< w:
        let i = y * w + x
        if known[i]: continue
        var n = 0
        var r, g, b = 0
        for dy in -1 .. 1:
          for dx in -1 .. 1:
            let xx = x + dx
            let yy = y + dy
            if xx < 0 or yy < 0 or xx >= w or yy >= h or not known[yy * w + xx]: continue
            let c = L.px[yy * w + xx]
            r += rOf(c); g += gOf(c); b += bOf(c)
            inc n
        if n > 0: next.add (i, argb(255, r div n, g div n, b div n))
    if next.len == 0: break
    for (i, c) in next:
      L.px[i] = c
      known[i] = true
      dec left

proc onionFill(L: var CafLevel) =
  ## The hole filled from its edge inward, ring by ring, each pixel the
  ## middle of the source patch most like what is known around it: the
  ## lines and edges that meet the hole go on into it (the start of the
  ## coarsest level).
  let w = L.w
  let h = L.h
  if L.sources.len == 0:
    L.diffuse()
    return
  var known = newSeq[bool](w * h)
  var left = 0
  for i in 0 ..< w * h:
    known[i] = not L.hole[i]
    if L.hole[i]: inc left
  let srcs = iptr(L.sources)
  let nsrc = L.sources.len
  while left > 0:
    # the ring: hole pixels next to what is known
    var ring: seq[int32]
    for y in 0 ..< h:
      for x in 0 ..< w:
        let i = y * w + x
        if known[i]: continue
        var near = false
        for dy in -1 .. 1:
          for dx in -1 .. 1:
            let xx = x + dx
            let yy = y + dy
            if xx >= 0 and yy >= 0 and xx < w and yy < h and known[yy * w + xx]: near = true
        if near: ring.add int32(i)
    if ring.len == 0:
      L.diffuse()
      return
    var got = newSeq[uint32](ring.len)
    var gotNnf = newSeq[int32](ring.len)
    let px = pptr(L.px)
    let kn = bptr(known)
    let rp = iptr(ring)
    let gp = pptr(got)
    let np = iptr(gotNnf)
    parallelFor(ring.len, proc (lo, hi: int) =
      for k in lo ..< hi:
        let t = int(rp[k])
        let tx = t mod w
        let ty = t div w
        var best = high(int)
        var bs = int(srcs[0])
        for j in 0 ..< nsrc:
          let sI = int(srcs[j])
          let sx = sI mod w
          let sy = sI div w
          var sum = 0
          var n = 0
          for dy in -PR .. PR:
            let y = ty + dy
            if y < 0 or y >= h: continue
            for dx in -PR .. PR:
              let x = tx + dx
              if x < 0 or x >= w or not kn[y * w + x]: continue
              let a = px[y * w + x]
              let b = px[(sy + dy) * w + sx + dx]
              let dr = int((a shr 16) and 255) - int((b shr 16) and 255)
              let dg = int((a shr 8) and 255) - int((b shr 8) and 255)
              let db = int(a and 255) - int(b and 255)
              sum += dr * dr + dg * dg + db * db
              inc n
          if n == 0: continue
          let d = sum * 64 div n
          if d < best:
            best = d
            bs = sI
        gp[k] = px[bs]
        np[k] = int32(bs), grain = 4)
    for k, t in ring:
      L.px[t] = got[k]
      L.nnf[t] = gotNnf[k]
      known[t] = true
      dec left

proc exemplarFill(L: var CafLevel) =
  ## The hole filled patch by patch from its edge, the edges and lines that
  ## run into it first (exemplar-based, as Criminisi): each time, the patch
  ## on the hole's edge whose known part is surest and where a line meets
  ## the edge, filled from the source patch most like its known part. The
  ## start of the coarsest level.
  let w = L.w
  let h = L.h
  let n = w * h
  if L.sources.len == 0:
    L.diffuse()
    return
  var known = newSeq[bool](n)
  var conf = newSeq[float32](n)
  var left = 0
  for i in 0 ..< n:
    known[i] = not L.hole[i]
    if known[i]: conf[i] = 1 else: inc left
  var lum = newSeq[float32](n)
  for i in 0 ..< n:
    let p = L.px[i]
    lum[i] = 0.299'f32 * float32((p shr 16) and 255) + 0.587'f32 * float32((p shr 8) and 255) +
             0.114'f32 * float32(p and 255)
  let srcs = iptr(L.sources)
  let nsrc = L.sources.len
  var guard = 0
  while left > 0 and guard < n:
    inc guard
    # the best place on the edge
    var best = -1.0
    var bp = -1
    for y in 0 ..< h:
      for x in 0 ..< w:
        let i = y * w + x
        if known[i]: continue
        var edge = false
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
          if nx >= 0 and ny >= 0 and nx < w and ny < h and known[ny * w + nx]: edge = true
        if not edge: continue
        # how sure: the known part of the patch
        var c = 0.0
        var cnt = 0
        # the hole's normal here, and the strongest line among the known
        var nxs, nys = 0.0
        var gx, gy, gm = 0.0
        for dy in -PR .. PR:
          for dx in -PR .. PR:
            let xx = x + dx
            let yy = y + dy
            if xx < 0 or yy < 0 or xx >= w or yy >= h: continue
            inc cnt
            let j = yy * w + xx
            if known[j]:
              c += conf[j]
              nxs -= dx.float
              nys -= dy.float
              if xx > 0 and xx + 1 < w and yy > 0 and yy + 1 < h and known[j - 1] and known[j + 1] and
                 known[j - w] and known[j + w]:
                let ax = float(lum[j + 1] - lum[j - 1]) / 2
                let ay = float(lum[j + w] - lum[j - w]) / 2
                let m = ax * ax + ay * ay
                if m > gm:
                  gm = m
                  gx = ax
                  gy = ay
        c /= max(1, cnt).float
        let nl = sqrt(nxs * nxs + nys * nys)
        var data = 0.001
        if nl > 0 and gm > 0:
          # the isophote (along the line) against the normal
          data += abs(-gy * nxs / nl + gx * nys / nl) / 255
        let pr = c * data
        if pr > best:
          best = pr
          bp = i
    if bp < 0: break
    # the most alike source patch, by the known part
    let tx = bp mod w
    let ty = bp div w
    var bestD = high(int)
    var bs = int(srcs[0])
    for k in 0 ..< nsrc:
      let sI = int(srcs[k])
      let sx = sI mod w
      let sy = sI div w
      var sum = 0
      for dy in -PR .. PR:
        let yy = ty + dy
        if yy < 0 or yy >= h: continue
        for dx in -PR .. PR:
          let xx = tx + dx
          if xx < 0 or xx >= w or not known[yy * w + xx]: continue
          let a = L.px[yy * w + xx]
          let b = L.px[(sy + dy) * w + sx + dx]
          let dr = int((a shr 16) and 255) - int((b shr 16) and 255)
          let dg = int((a shr 8) and 255) - int((b shr 8) and 255)
          let db = int(a and 255) - int(b and 255)
          sum += dr * dr + dg * dg + db * db
        if sum >= bestD: break
      if sum < bestD:
        bestD = sum
        bs = sI
    let sx = bs mod w
    let sy = bs div w
    let cNew = conf[bp]
    var cSum = 0.0
    var cCnt = 0
    for dy in -PR .. PR:
      for dx in -PR .. PR:
        let xx = tx + dx
        let yy = ty + dy
        if xx < 0 or yy < 0 or xx >= w or yy >= h: continue
        let j = yy * w + xx
        inc cCnt
        if known[j]: cSum += conf[j]
    let c = float32(cSum / max(1, cCnt).float)
    discard cNew
    for dy in -PR .. PR:
      for dx in -PR .. PR:
        let xx = tx + dx
        let yy = ty + dy
        if xx < 0 or yy < 0 or xx >= w or yy >= h: continue
        let j = yy * w + xx
        if known[j]: continue
        let q = (sy + dy) * w + sx + dx
        L.px[j] = L.px[q]
        lum[j] = lum[q]
        conf[j] = c
        known[j] = true
        dec left

proc randomMatches(L: var CafLevel; seed: int) =
  var rng = (uint32(seed) * 2654435761'u32 + 1) or 1
  for t in L.targets:
    rng = rng xor (rng shl 13); rng = rng xor (rng shr 17); rng = rng xor (rng shl 5)
    L.nnf[t] = L.sources[int(rng mod uint32(L.sources.len))]

proc holeRadius(hole: openArray[uint8]; w, h: int): int =
  ## How far the middle of the hole is from its edge (in pixels, 8 ways).
  var d = newSeq[int32](w * h)
  const big = 1_000_000'i32
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      if hole[i] == 0: continue
      var v = big
      if x > 0: v = min(v, d[i - 1] + 1)
      if y > 0:
        v = min(v, d[i - w] + 1)
        if x > 0: v = min(v, d[i - w - 1] + 1)
        if x + 1 < w: v = min(v, d[i - w + 1] + 1)
      if x == 0 or y == 0 or x == w - 1 or y == h - 1: v = min(v, 1)
      d[i] = v
  for y in countdown(h - 1, 0):
    for x in countdown(w - 1, 0):
      let i = y * w + x
      if hole[i] == 0: continue
      var v = d[i]
      if x + 1 < w: v = min(v, d[i + 1] + 1)
      if y + 1 < h:
        v = min(v, d[i + w] + 1)
        if x + 1 < w: v = min(v, d[i + w + 1] + 1)
        if x > 0: v = min(v, d[i + w - 1] + 1)
      d[i] = v
      result = max(result, int(v))

proc contentAwareFill*(src: Img; hole: openArray[uint8]; seed = 1): Img =
  ## Content-Aware Fill: the pixels of `src` where `hole` is not 0 made
  ## again from the rest of it, patch by patch, so they continue what is
  ## around them (PatchMatch, from a small copy up). Alpha is kept.
  result = src
  let w = src.w
  let h = src.h
  if w <= 0 or h <= 0 or hole.len < w * h: return
  let hb = bounds(hole, w, h)
  if hb.w <= 0: return
  # the levels: halved until the hole is small
  var levels: seq[CafLevel]
  var L0 = CafLevel(w: w, h: h, px: src.px, hole: newSeq[bool](w * h))
  for i in 0 ..< w * h:
    L0.hole[i] = hole[i] != 0
    L0.px[i] = L0.px[i] or 0xFF000000'u32
  levels.add L0
  # (as many levels as make the hole a few pixels thick: a long thin hole
  # keeps its detail)
  var hm = holeRadius(hole, w, h)
  while hm > 5 and min(levels[^1].w, levels[^1].h) div 2 >= 3 * (2 * PR + 1):
    let a = levels[^1]
    let cw = (a.w + 1) div 2
    let ch = (a.h + 1) div 2
    var c = CafLevel(w: cw, h: ch, px: newSeq[uint32](cw * ch), hole: newSeq[bool](cw * ch))
    for y in 0 ..< ch:
      for x in 0 ..< cw:
        var r, g, b, n = 0
        var anyHole = false
        for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)]:
          let fx = min(2 * x + dx, a.w - 1)
          let fy = min(2 * y + dy, a.h - 1)
          let i = fy * a.w + fx
          if a.hole[i]: anyHole = true
          else:
            let p = a.px[i]
            r += rOf(p); g += gOf(p); b += bOf(p)
            inc n
        c.hole[y * cw + x] = anyHole
        c.px[y * cw + x] = if n > 0: argb(255, r div n, g div n, b div n) else: 0xFF808080'u32
    levels.add c
    hm = (hm + 1) div 2
  for L in levels.mitems: L.setup()
  # coarsest: a guess from the edge, then matches at random made better
  var top = levels.len - 1
  while top > 0 and levels[top].sources.len < 8: dec top
  if levels[top].sources.len == 0:
    levels[top].diffuse()
  else:
    levels[top].exemplarFill()
    levels[top].randomMatches(seed)
    levels[top].costs()
    for it in 0 ..< 4: levels[top].search(it, seed)
    for em in 0 ..< 8:
      for it in 0 ..< (if em == 0: 4 else: 2): levels[top].search(it, seed + em * 31)
      levels[top].vote()
      levels[top].costs()
  # finer and finer: the matches made twice as big, then better
  for k in countdown(top - 1, 0):
    let c = addr levels[k + 1]
    let f = addr levels[k]
    for y in 0 ..< f.h:
      for x in 0 ..< f.w:
        let i = y * f.w + x
        if f.hole[i]: f.px[i] = c.px[min(y div 2, c.h - 1) * c.w + min(x div 2, c.w - 1)]
    if f.sources.len == 0:
      continue
    var rng = uint32(seed * 97 + k * 13) or 1
    for t in f.targets:
      let x = t mod f.w
      let y = t div f.w
      let cm = c.nnf[min(y div 2, c.h - 1) * c.w + min(x div 2, c.w - 1)]
      var s = -1
      if cm >= 0:
        let sx = clamp(2 * (cm mod c.w) + (x and 1), 0, f.w - 1)
        let sy = clamp(2 * (cm div c.w) + (y and 1), 0, f.h - 1)
        if f.valid[sy * f.w + sx]: s = sy * f.w + sx
      if s < 0:
        rng = rng xor (rng shl 13); rng = rng xor (rng shr 17); rng = rng xor (rng shl 5)
        s = f.sources[int(rng mod uint32(f.sources.len))]
      f.nnf[t] = int32(s)
    f[].costs()
    f[].vote()
    let ems = if k == 0: 4 else: 6
    for em in 0 ..< ems:
      f[].costs()
      for it in 0 ..< 2: f[].search(it, seed + k * 1000 + em * 31)
      f[].vote(if k == 0 and em == ems - 1: 4.0 else: 1.0)
  # the colors made to meet: what the patches say the hole's edge should
  # be, against what it is, smoothed into the hole (a gradient goes on, the
  # light of the surroundings is kept)
  block adapt:
    let L = addr levels[0]
    if L.sources.len == 0: break adapt
    let s2 = block:
      var sample: seq[int32]
      let step = max(1, L.targets.len div 2000)
      var k = 0
      while k < L.targets.len:
        sample.add L.cost[L.targets[k]]
        k += step
      sample.sort()
      max(1.0, sample[sample.len * 3 div 4].float)
    var v = newSeq[float32](w * h * 3)
    var fixed = newSeq[bool](w * h)
    for i in 0 ..< w * h: fixed[i] = not L.hole[i]
    var ring = 0
    for y in 0 ..< h:
      for x in 0 ..< w:
        let p = y * w + x
        if L.hole[p]: continue
        var nearHole = false
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
          if nx >= 0 and ny >= 0 and nx < w and ny < h and L.hole[ny * w + nx]: nearHole = true
        if not nearHole: continue
        var sr, sg, sb, sw = 0.0
        for dy in -PR .. PR:
          let ty = y - dy
          if ty < 0 or ty >= h: continue
          for dx in -PR .. PR:
            let tx = x - dx
            if tx < 0 or tx >= w: continue
            let m = int(L.nnf[ty * w + tx])
            if m < 0: continue
            let c = L.px[(m div w + dy) * w + m mod w + dx]
            let wt = exp(-L.cost[ty * w + tx].float / (2 * s2))
            sr += float((c shr 16) and 255) * wt
            sg += float((c shr 8) and 255) * wt
            sb += float(c and 255) * wt
            sw += wt
        if sw <= 0: continue
        let o = L.px[p]
        v[p * 3] = float32(rOf(o).float - sr / sw)
        v[p * 3 + 1] = float32(gOf(o).float - sg / sw)
        v[p * 3 + 2] = float32(bOf(o).float - sb / sw)
        inc ring
    if ring == 0: break adapt
    # (along the edge, smoothed: texture is not a difference of light)
    var sm = v
    for y in 0 ..< h:
      for x in 0 ..< w:
        let p = y * w + x
        if L.hole[p] or (v[p * 3] == 0 and v[p * 3 + 1] == 0 and v[p * 3 + 2] == 0): continue
        var a: array[3, float32]
        var n = 0'f32
        for dy in -3 .. 3:
          for dx in -3 .. 3:
            let xx = x + dx
            let yy = y + dy
            if xx < 0 or yy < 0 or xx >= w or yy >= h: continue
            let q = yy * w + xx
            if L.hole[q] or (v[q * 3] == 0 and v[q * 3 + 1] == 0 and v[q * 3 + 2] == 0): continue
            for c in 0 .. 2: a[c] += v[q * 3 + c]
            n += 1
        for c in 0 .. 2: sm[p * 3 + c] = a[c] / n
    membrane(sm, fixed, w, h)
    for i in 0 ..< w * h:
      if L.hole[i]:
        let c = L.px[i]
        L.px[i] = argb(255, clamp(int(round(rOf(c).float32 + sm[i * 3])), 0, 255),
                       clamp(int(round(gOf(c).float32 + sm[i * 3 + 1])), 0, 255),
                       clamp(int(round(bOf(c).float32 + sm[i * 3 + 2])), 0, 255))
  # the hole of the picture, alpha as it was
  for i in 0 ..< w * h:
    if levels[0].hole[i]:
      result.px[i] = (src.px[i] and 0xFF000000'u32) or (levels[0].px[i] and 0xFFFFFF'u32)
      if (src.px[i] shr 24) == 0: result.px[i] = levels[0].px[i]

# ---- red eye ----------------------------------------------------------------------------------------------

proc redEye*(src: Img; cx, cy, radius: int; darken = 50): Img =
  ## The red of an eye's pupil near `cx`, `cy` (within `radius`) made dark
  ## and neutral; the glint kept.
  result = src
  let w = src.w
  let h = src.h
  if w <= 0 or h <= 0 or radius <= 0: return
  template redness(p: uint32): int =
    (let r = rOf(p); let m = max(gOf(p), bOf(p)); if r > 50 and r * 10 > m * 15: r - m else: 0)
  # the reddest pixel near the middle
  var best = -1
  var bestScore = 0
  for y in max(0, cy - radius) .. min(h - 1, cy + radius):
    for x in max(0, cx - radius) .. min(w - 1, cx + radius):
      let d2 = (x - cx) ^ 2 + (y - cy) ^ 2
      if d2 > radius * radius: continue
      let s = redness(src.px[y * w + x]) * 4 - d2 * 40 div max(1, radius * radius)
      if s > bestScore:
        bestScore = s
        best = y * w + x
  if best < 0: return
  # the red pixels joined to it
  var mask = newSeq[uint8](w * h)
  var stack = @[best]
  mask[best] = 255
  let minRed = max(8, bestScore div 4 div 3)
  while stack.len > 0:
    let i = stack.pop()
    let x = i mod w
    let y = i div w
    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
      if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
      if (nx - cx) ^ 2 + (ny - cy) ^ 2 > radius * radius * 2: continue
      let j = ny * w + nx
      if mask[j] != 0 or redness(src.px[j]) < minRed: continue
      mask[j] = 255
      stack.add j
  # a soft edge, a pixel wide
  var soft = mask
  for y in 0 ..< h:
    for x in 0 ..< w:
      if mask[y * w + x] != 0: continue
      var n = 0
      for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
        if nx >= 0 and ny >= 0 and nx < w and ny < h and mask[ny * w + nx] != 0: inc n
      if n > 0: soft[y * w + x] = uint8(min(255, n * 70))
  let k = 1 - clamp(darken, 0, 100) / 100 * 0.7
  for i in 0 ..< w * h:
    let m = int(soft[i])
    if m == 0: continue
    let p = src.px[i]
    let g = gOf(p)
    let b = bOf(p)
    var v = (g + b) div 2
    if min(rOf(p), min(g, b)) < 200: v = int(v.float * k)       # (not the glint)
    let r2 = rOf(p) + (v - rOf(p)) * m div 255
    let g2 = g + (int(g.float * (if v < g: k else: 1.0)) - g) * m div 255
    let b2 = b + (int(b.float * (if v < b: k else: 1.0)) - b) * m div 255
    result.px[i] = argb(aOf(p), r2, g2, b2)

# ---- the least cut of a graph (Boykov-Kolmogorov) ----------------------------------------------------------

type
  CutGraph* = object
    ## A graph to cut in two -- the source's side and the sink's -- at the
    ## least cost (the maximum flow). For pictures: a node a pixel.
    head, next, sister: seq[int32]       # per arc
    cap: seq[float32]                    # per arc: what can still flow
    first: seq[int32]                    # per node: its first arc
    trCap: seq[float32]                  # per node: from the source (+) or to the sink (-)
    parent: seq[int32]
    isSink: seq[bool]
    ts, dist: seq[int32]
    nextActive: seq[int32]
    qFirst, qLast: int32
    orphans: seq[int32]
    time: int32
    flow*: float                         ## the flow found so far: the cut's cost

const
  NoArc = -1'i32
  Terminal = -2'i32
  Orphan = -3'i32

proc initCutGraph*(n: int; arcs = 0): CutGraph =
  ## A graph of `n` nodes (room for about `arcs` arcs).
  result.first = newSeq[int32](n)
  for v in result.first.mitems: v = NoArc
  result.trCap = newSeq[float32](n)
  result.head = newSeqOfCap[int32](arcs)
  result.next = newSeqOfCap[int32](arcs)
  result.sister = newSeqOfCap[int32](arcs)
  result.cap = newSeqOfCap[float32](arcs)

proc addEdge*(g: var CutGraph; i, j: int; capIJ, capJI: float32) =
  ## An edge between nodes `i` and `j` that carries `capIJ` from i to j and
  ## `capJI` back.
  let a = int32(g.head.len)
  g.head.add int32(j); g.next.add g.first[i]; g.first[i] = a; g.cap.add capIJ; g.sister.add a + 1
  g.head.add int32(i); g.next.add g.first[j]; g.first[j] = a + 1; g.cap.add capJI; g.sister.add a

proc addTerminal*(g: var CutGraph; i: int; source, sink: float32) =
  ## What it costs to put node `i` on the sink's side (`source`) or on the
  ## source's (`sink`).
  var s = source
  var t = sink
  let d = g.trCap[i]
  if d > 0: s += d else: t -= d
  g.flow += min(s, t).float
  g.trCap[i] = s - t

{.push boundChecks: off, overflowChecks: off.}

proc setActive(g: var CutGraph; i: int32) =
  if g.nextActive[i] == NoArc:
    if g.qLast >= 0: g.nextActive[g.qLast] = i
    else: g.qFirst = i
    g.qLast = i
    g.nextActive[i] = i

proc nextActiveNode(g: var CutGraph): int32 =
  while true:
    let i = g.qFirst
    if i < 0: return -1
    if g.nextActive[i] == i:
      g.qFirst = -1
      g.qLast = -1
    else: g.qFirst = g.nextActive[i]
    g.nextActive[i] = NoArc
    if g.parent[i] != NoArc: return i

proc orphan(g: var CutGraph; i: int32) =
  g.parent[i] = Orphan
  g.orphans.add i

proc augment(g: var CutGraph; mid: int32) =
  var b = g.cap[mid]
  var u = g.head[g.sister[mid]]
  while true:
    let pa = g.parent[u]
    if pa == Terminal: break
    b = min(b, g.cap[g.sister[pa]])
    u = g.head[pa]
  b = min(b, g.trCap[u])
  var v = g.head[mid]
  while true:
    let pa = g.parent[v]
    if pa == Terminal: break
    b = min(b, g.cap[pa])
    v = g.head[pa]
  b = min(b, -g.trCap[v])
  # push it along
  g.cap[g.sister[mid]] += b
  g.cap[mid] -= b
  u = g.head[g.sister[mid]]
  while true:
    let pa = g.parent[u]
    if pa == Terminal: break
    g.cap[pa] += b
    g.cap[g.sister[pa]] -= b
    let nxt = g.head[pa]
    if g.cap[g.sister[pa]] <= 0: g.orphan(u)
    u = nxt
  g.trCap[u] -= b
  if g.trCap[u] <= 0: g.orphan(u)
  v = g.head[mid]
  while true:
    let pa = g.parent[v]
    if pa == Terminal: break
    g.cap[g.sister[pa]] += b
    g.cap[pa] -= b
    let nxt = g.head[pa]
    if g.cap[pa] <= 0: g.orphan(v)
    v = nxt
  g.trCap[v] += b
  if g.trCap[v] >= 0: g.orphan(v)
  g.flow += b.float

proc adopt(g: var CutGraph; i: int32) =
  ## A node cut off from its tree looks for a new parent in it, or leaves.
  let sinkSide = g.isSink[i]
  var a0 = NoArc
  var dmin = high(int32)
  var a = g.first[i]
  while a != NoArc:
    let open = if sinkSide: g.cap[a] > 0 else: g.cap[g.sister[a]] > 0
    let j = g.head[a]
    if open and g.isSink[j] == sinkSide and g.parent[j] != NoArc:
      # is j's tree still rooted at the terminal?
      var d = 0'i32
      var k = j
      var ok = true
      while true:
        if g.ts[k] == g.time:
          d += g.dist[k]
          break
        let pa = g.parent[k]
        inc d
        if pa == Terminal:
          g.ts[k] = g.time
          g.dist[k] = 1
          break
        if pa == Orphan:
          ok = false
          break
        k = g.head[pa]
      if ok:
        if d < dmin:
          a0 = a
          dmin = d
        k = j
        while g.ts[k] != g.time:
          g.ts[k] = g.time
          g.dist[k] = d
          dec d
          k = g.head[g.parent[k]]
    a = g.next[a]
  g.parent[i] = a0
  if a0 != NoArc:
    g.ts[i] = g.time
    g.dist[i] = dmin + 1
    return
  # free: its children are orphans, its neighbours may grow into it
  g.parent[i] = NoArc
  a = g.first[i]
  while a != NoArc:
    let j = g.head[a]
    let pj = g.parent[j]
    if g.isSink[j] == sinkSide and pj != NoArc:
      let open = if sinkSide: g.cap[a] > 0 else: g.cap[g.sister[a]] > 0
      if open: g.setActive(j)
      if pj != Terminal and pj != Orphan and g.head[pj] == i: g.orphan(j)
    a = g.next[a]

proc maxflow*(g: var CutGraph): float =
  ## Cuts the graph; the flow (the cut's cost).
  let n = g.first.len
  g.parent = newSeq[int32](n)
  g.isSink = newSeq[bool](n)
  g.ts = newSeq[int32](n)
  g.dist = newSeq[int32](n)
  g.nextActive = newSeq[int32](n)
  g.qFirst = -1
  g.qLast = -1
  g.time = 0
  for i in 0 ..< n:
    g.nextActive[i] = NoArc
    if g.trCap[i] > 0:
      g.isSink[i] = false
      g.parent[i] = Terminal
      g.setActive(int32(i))
      g.dist[i] = 1
    elif g.trCap[i] < 0:
      g.isSink[i] = true
      g.parent[i] = Terminal
      g.setActive(int32(i))
      g.dist[i] = 1
    else:
      g.parent[i] = NoArc
  var cur = -1'i32
  while true:
    var i = cur
    if i >= 0:
      g.nextActive[i] = NoArc
      if g.parent[i] == NoArc: i = -1
    if i < 0:
      i = g.nextActiveNode()
      if i < 0: break
    # grow the tree from i
    var found = NoArc
    var a = g.first[i]
    if not g.isSink[i]:
      while a != NoArc:
        if g.cap[a] > 0:
          let j = g.head[a]
          if g.parent[j] == NoArc:
            g.isSink[j] = false
            g.parent[j] = g.sister[a]
            g.ts[j] = g.ts[i]
            g.dist[j] = g.dist[i] + 1
            g.setActive(j)
          elif g.isSink[j]:
            found = a
            break
          elif g.ts[j] <= g.ts[i] and g.dist[j] > g.dist[i]:
            g.parent[j] = g.sister[a]
            g.ts[j] = g.ts[i]
            g.dist[j] = g.dist[i] + 1
        a = g.next[a]
    else:
      while a != NoArc:
        if g.cap[g.sister[a]] > 0:
          let j = g.head[a]
          if g.parent[j] == NoArc:
            g.isSink[j] = true
            g.parent[j] = g.sister[a]
            g.ts[j] = g.ts[i]
            g.dist[j] = g.dist[i] + 1
            g.setActive(j)
          elif not g.isSink[j]:
            found = g.sister[a]
            break
          elif g.ts[j] <= g.ts[i] and g.dist[j] > g.dist[i]:
            g.parent[j] = g.sister[a]
            g.ts[j] = g.ts[i]
            g.dist[j] = g.dist[i] + 1
        a = g.next[a]
    inc g.time
    if found != NoArc:
      g.nextActive[i] = i               # (kept: it grows again next)
      cur = i
      g.augment(found)
      while g.orphans.len > 0:
        let o = g.orphans.pop()
        g.adopt(o)
    else:
      cur = -1
  g.flow

{.pop.}

proc sourceSide*(g: CutGraph; i: int): bool =
  ## After `maxflow`: node `i` is on the source's side.
  g.parent.len > i and g.parent[i] != NoArc and not g.isSink[i]

# ---- color models: mixtures of gaussians -------------------------------------------------------------------

type
  Gauss = object
    mean: array[3, float]
    inv: array[9, float]                 # the covariance inverted
    lnNorm: float                        # ln(weight) - ln det / 2 - 3/2 ln 2 pi
  Gmm = object
    g: seq[Gauss]

  Col = array[3, float32]

proc maha(g: Gauss; x: Col): float {.inline.} =
  let d0 = x[0].float - g.mean[0]
  let d1 = x[1].float - g.mean[1]
  let d2 = x[2].float - g.mean[2]
  d0 * (g.inv[0] * d0 + g.inv[1] * d1 + g.inv[2] * d2) +
    d1 * (g.inv[3] * d0 + g.inv[4] * d1 + g.inv[5] * d2) +
    d2 * (g.inv[6] * d0 + g.inv[7] * d1 + g.inv[8] * d2)

proc bestOf(m: Gmm; x: Col): int =
  var best = -Inf
  for k, g in m.g:
    let v = g.lnNorm - 0.5 * g.maha(x)
    if v > best:
      best = v
      result = k

proc cost(m: Gmm; x: Col): float =
  ## -ln of how likely the color is under the model.
  var mx = -Inf
  var vals: array[8, float]
  for k, g in m.g:
    vals[k] = g.lnNorm - 0.5 * g.maha(x)
    mx = max(mx, vals[k])
  if mx == -Inf: return 50
  var s = 0.0
  for k in 0 ..< m.g.len: s += exp(vals[k] - mx)
  min(50.0, -(mx + ln(s)))

proc learn(m: var Gmm; col: seq[Col]; members: seq[int32]; comp: seq[int8]; k: int) =
  ## The model's components from their pixels.
  m.g.setLen(0)
  var n = newSeq[float](k)
  var sum = newSeq[array[3, float]](k)
  var sq = newSeq[array[9, float]](k)
  for i in members:
    let c = int(comp[i])
    let x = col[i]
    n[c] += 1
    for a in 0 .. 2:
      sum[c][a] += x[a]
      for b in 0 .. 2: sq[c][a * 3 + b] += x[a].float * x[b].float
  let total = max(1.0, members.len.float)
  for c in 0 ..< k:
    if n[c] < 3: continue
    var g: Gauss
    var cov: array[9, float]
    for a in 0 .. 2: g.mean[a] = sum[c][a] / n[c]
    for a in 0 .. 2:
      for b in 0 .. 2: cov[a * 3 + b] = sq[c][a * 3 + b] / n[c] - g.mean[a] * g.mean[b]
    for a in 0 .. 2: cov[a * 4] += 2.0           # (never flat)
    let det = cov[0] * (cov[4] * cov[8] - cov[5] * cov[7]) - cov[1] * (cov[3] * cov[8] - cov[5] * cov[6]) +
              cov[2] * (cov[3] * cov[7] - cov[4] * cov[6])
    if det <= 1e-9: continue
    let id = 1 / det
    g.inv = [(cov[4] * cov[8] - cov[5] * cov[7]) * id, (cov[2] * cov[7] - cov[1] * cov[8]) * id,
             (cov[1] * cov[5] - cov[2] * cov[4]) * id, (cov[5] * cov[6] - cov[3] * cov[8]) * id,
             (cov[0] * cov[8] - cov[2] * cov[6]) * id, (cov[2] * cov[3] - cov[0] * cov[5]) * id,
             (cov[3] * cov[7] - cov[4] * cov[6]) * id, (cov[1] * cov[6] - cov[0] * cov[7]) * id,
             (cov[0] * cov[4] - cov[1] * cov[3]) * id]
    g.lnNorm = ln(n[c] / total) - 0.5 * ln(det) - 1.5 * ln(2 * PI)
    m.g.add g

proc kmeans(col: seq[Col]; members: seq[int32]; k: int): seq[int8] =
  ## Each member's cluster of `k` (by color), as a start for a model.
  result = newSeq[int8](col.len)
  if members.len == 0: return
  # centers spread through the members by lightness
  var order = members
  order.sort(proc (a, b: int32): int = cmp(col[a][0] + col[a][1] + col[a][2], col[b][0] + col[b][1] + col[b][2]))
  var centers = newSeq[Col](k)
  for c in 0 ..< k: centers[c] = col[order[(order.len - 1) * (2 * c + 1) div (2 * k)]]
  let step = max(1, members.len div 30000)
  for it in 0 ..< 8:
    var s = newSeq[array[3, float]](k)
    var n = newSeq[int](k)
    var j = 0
    while j < members.len:
      let x = col[members[j]]
      var best = 0
      var bd = Inf
      for c in 0 ..< k:
        let d = (x[0] - centers[c][0]) ^ 2 + (x[1] - centers[c][1]) ^ 2 + (x[2] - centers[c][2]) ^ 2
        if d < bd:
          bd = d
          best = c
      for a in 0 .. 2: s[best][a] += x[a]
      inc n[best]
      j += step
    for c in 0 ..< k:
      if n[c] > 0:
        for a in 0 .. 2: centers[c][a] = float32(s[c][a] / n[c].float)
  for i in members:
    let x = col[i]
    var best = 0
    var bd = Inf
    for c in 0 ..< k:
      let d = (x[0] - centers[c][0]) ^ 2 + (x[1] - centers[c][1]) ^ 2 + (x[2] - centers[c][2]) ^ 2
      if d < bd:
        bd = d
        best = c
    result[i] = int8(best)

# ---- GrabCut ----------------------------------------------------------------------------------------------

proc grabCut(col: seq[Col]; w, h: int; fg: var seq[bool]; hard: seq[int8]; iters = 4; gamma = 50.0) =
  ## What is in front, in `fg`, made better: color models of the two sides
  ## and the least cut between them that follows the edges. `hard`: 1 is in
  ## front, -1 behind, 0 to find out.
  let n = w * h
  if n == 0: return
  const K = 5
  # how much a difference of color between neighbours costs, on average
  var s = 0.0
  var cnt = 0
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      for (dx, dy) in [(1, 0), (0, 1), (1, 1), (-1, 1)]:
        let xx = x + dx
        let yy = y + dy
        if xx < 0 or xx >= w or yy >= h: continue
        let j = yy * w + xx
        s += float((col[i][0] - col[j][0]) ^ 2 + (col[i][1] - col[j][1]) ^ 2 + (col[i][2] - col[j][2]) ^ 2)
        inc cnt
  let beta = if s > 0: 1 / (2 * s / max(1, cnt).float) else: 0.0
  var pairs: seq[(int32, int32, float32)]
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      for (dx, dy) in [(1, 0), (0, 1), (1, 1), (-1, 1)]:
        let xx = x + dx
        let yy = y + dy
        if xx < 0 or xx >= w or yy >= h: continue
        let j = yy * w + xx
        let d = float((col[i][0] - col[j][0]) ^ 2 + (col[i][1] - col[j][1]) ^ 2 + (col[i][2] - col[j][2]) ^ 2)
        let wt = gamma * exp(-beta * d) / (if dx != 0 and dy != 0: sqrt(2.0) else: 1.0)
        pairs.add (int32(i), int32(j), float32(wt))
  var comp = newSeq[int8](n)
  for it in 0 ..< iters:
    var fgM, bgM: Gmm
    var fgIdx, bgIdx: seq[int32]
    for i in 0 ..< n:
      if fg[i]: fgIdx.add int32(i) else: bgIdx.add int32(i)
    if fgIdx.len < 10 or bgIdx.len < 10: return
    if it == 0:
      let a = kmeans(col, fgIdx, K)
      let b = kmeans(col, bgIdx, K)
      for i in fgIdx: comp[i] = a[i]
      for i in bgIdx: comp[i] = b[i]
      fgM.learn(col, fgIdx, comp, K)
      bgM.learn(col, bgIdx, comp, K)
    else:
      fgM.learn(col, fgIdx, comp, K)
      bgM.learn(col, bgIdx, comp, K)
      for i in fgIdx: comp[i] = int8(fgM.bestOf(col[i]))
      for i in bgIdx: comp[i] = int8(bgM.bestOf(col[i]))
      fgM.learn(col, fgIdx, comp, K)
      bgM.learn(col, bgIdx, comp, K)
    if fgM.g.len == 0 or bgM.g.len == 0: return
    var g = initCutGraph(n, pairs.len * 2)
    for i in 0 ..< n:
      case hard[i]
      of 1: g.addTerminal(i, 1e5, 0)
      of -1: g.addTerminal(i, 0, 1e5)
      else: g.addTerminal(i, float32(bgM.cost(col[i])), float32(fgM.cost(col[i])))
    for (i, j, wt) in pairs: g.addEdge(i, j, wt, wt)
    discard g.maxflow()
    var changed = 0
    for i in 0 ..< n:
      let v = g.sourceSide(i)
      if v != fg[i]: inc changed
      fg[i] = v
    if changed * 1000 < n: break

# ---- what the selection tools share --------------------------------------------------------------------------

proc labOf(p: uint32): Col =
  ## CIE Lab (D65) of a pixel.
  template lin(v: int): float =
    (let c = v / 255; if c <= 0.04045: c / 12.92 else: pow((c + 0.055) / 1.055, 2.4))
  let r = lin(rOf(p))
  let g = lin(gOf(p))
  let b = lin(bOf(p))
  let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
  let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
  let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
  template f(t: float): float = (if t > 0.008856: cbrt(t) else: 7.787 * t + 16 / 116)
  [float32(116 * f(y) - 16), float32(500 * (f(x) - f(y))), float32(200 * (f(y) - f(z)))]

proc components(m: seq[bool]; w, h: int): (seq[int32], seq[int]) =
  ## The parts of `m` (4 ways joined): each pixel's part (-1: none) and each
  ## part's size.
  var id = newSeq[int32](w * h)
  for v in id.mitems: v = -1
  var sizes: seq[int]
  var stack: seq[int]
  for s in 0 ..< w * h:
    if not m[s] or id[s] >= 0: continue
    let k = int32(sizes.len)
    sizes.add 0
    stack.add s
    id[s] = k
    while stack.len > 0:
      let i = stack.pop()
      inc sizes[k]
      let x = i mod w
      let y = i div w
      for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
        if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
        let j = ny * w + nx
        if m[j] and id[j] < 0:
          id[j] = k
          stack.add j
  (id, sizes)

proc fillHoles(m: var seq[bool]; w, h: int; most: int) =
  ## Holes in `m` (parts of what is not in it that do not reach the edge)
  ## of at most `most` pixels filled.
  var inv = newSeq[bool](w * h)
  for i in 0 ..< w * h: inv[i] = not m[i]
  let (id, sizes) = components(inv, w, h)
  var edge = newSeq[bool](sizes.len)
  for x in 0 ..< w:
    if id[x] >= 0: edge[id[x]] = true
    if id[(h - 1) * w + x] >= 0: edge[id[(h - 1) * w + x]] = true
  for y in 0 ..< h:
    if id[y * w] >= 0: edge[id[y * w]] = true
    if id[y * w + w - 1] >= 0: edge[id[y * w + w - 1]] = true
  for i in 0 ..< w * h:
    let k = id[i]
    if k >= 0 and not edge[k] and sizes[k] <= most: m[i] = true

proc boxBlur(v: var seq[float32]; w, h, r: int) =
  var tmp = newSeq[float32](w * h)
  var o = v
  for y in 0 ..< h:
    for x in 0 ..< w:
      var s = 0'f32
      var n = 0
      for k in max(0, x - r) .. min(w - 1, x + r):
        s += v[y * w + k]
        inc n
      tmp[y * w + x] = s / n.float32
  for y in 0 ..< h:
    for x in 0 ..< w:
      var s = 0'f32
      var n = 0
      for k in max(0, y - r) .. min(h - 1, y + r):
        s += tmp[k * w + x]
        inc n
      o[y * w + x] = s / n.float32
  v = o

proc maskUp(small: seq[bool]; sw, sh: int; src: Img; lum: seq[float32]): seq[uint8] =
  ## The small mask made as big as `src`, its edges following the picture's
  ## (a guided filter worked out small, read big).
  let w = src.w
  let h = src.h
  result = newSeq[uint8](w * h)
  if sw <= 0 or sh <= 0: return
  let n = sw * sh
  var p = newSeq[float32](n)
  for i in 0 ..< n: p[i] = if small[i]: 1 else: 0
  # the coefficients of the guided filter (guide: the small lightness)
  const r = 2
  const eps = 0.0016'f32
  var mI = lum
  var mP = p
  var mIP = newSeq[float32](n)
  var mII = newSeq[float32](n)
  for i in 0 ..< n:
    mIP[i] = lum[i] * p[i]
    mII[i] = lum[i] * lum[i]
  boxBlur(mI, sw, sh, r); boxBlur(mP, sw, sh, r); boxBlur(mIP, sw, sh, r); boxBlur(mII, sw, sh, r)
  var a = newSeq[float32](n)
  var b = newSeq[float32](n)
  for i in 0 ..< n:
    let v = mII[i] - mI[i] * mI[i]
    a[i] = (mIP[i] - mI[i] * mP[i]) / (v + eps)
    b[i] = mP[i] - a[i] * mI[i]
  boxBlur(a, sw, sh, r); boxBlur(b, sw, sh, r)
  let fx = sw / w
  let fy = sh / h
  let sp = pptr(src.px)
  let ap = fptr(a)
  let bp = fptr(b)
  let rp = cast[ptr UncheckedArray[uint8]](addr result[0])
  parallelRows(h, y):
    let syf = clamp((y.float + 0.5) * fy - 0.5, 0, float(sh - 1))
    let y0 = min(int(syf), sh - 1)
    let y1 = min(y0 + 1, sh - 1)
    let ty = float32(syf - y0.float)
    for x in 0 ..< w:
      let sxf = clamp((x.float + 0.5) * fx - 0.5, 0, float(sw - 1))
      let x0 = min(int(sxf), sw - 1)
      let x1 = min(x0 + 1, sw - 1)
      let tx = float32(sxf - x0.float)
      let A = (ap[y0 * sw + x0] * (1 - tx) + ap[y0 * sw + x1] * tx) * (1 - ty) +
              (ap[y1 * sw + x0] * (1 - tx) + ap[y1 * sw + x1] * tx) * ty
      let B = (bp[y0 * sw + x0] * (1 - tx) + bp[y0 * sw + x1] * tx) * (1 - ty) +
              (bp[y1 * sw + x0] * (1 - tx) + bp[y1 * sw + x1] * tx) * ty
      let c = sp[y * w + x]
      let I = (0.299'f32 * float32((c shr 16) and 255) + 0.587'f32 * float32((c shr 8) and 255) +
               0.114'f32 * float32(c and 255)) / 255
      let q = A * I + B
      # (a firm edge, a pixel or two soft)
      let t = clamp((q - 0.3'f32) / 0.4'f32, 0, 1)
      rp[y * w + x] = uint8(t * t * (3 - 2 * t) * 255 + 0.5)

proc proxyOf(src: Img; side: int): (Img, seq[Col], seq[float32]) =
  let s = smallCopy(src, side)
  var lab = newSeq[Col](s.w * s.h)
  var lum = newSeq[float32](s.w * s.h)
  for i in 0 ..< s.px.len:
    lab[i] = labOf(s.px[i])
    let p = s.px[i]
    lum[i] = (0.299'f32 * rOf(p).float32 + 0.587'f32 * gOf(p).float32 + 0.114'f32 * bOf(p).float32) / 255
  (s, lab, lum)

proc mbd(v: seq[float32]; seeds: seq[bool]; w, h: int): seq[float32] =
  ## The minimum barrier distance of each pixel from the seeds: over the
  ## paths to them, the least rise and fall of `v` along the way.
  let n = w * h
  result = newSeq[float32](n)
  var U = v
  var L = v
  for i in 0 ..< n: result[i] = if seeds[i]: 0 else: Inf
  for pass in 0 ..< 3:
    for y in 0 ..< h:
      for x in 0 ..< w:
        let i = y * w + x
        for (nx, ny) in [(x - 1, y), (x, y - 1)]:
          if nx < 0 or ny < 0: continue
          let j = ny * w + nx
          let u = max(U[j], v[i])
          let l = min(L[j], v[i])
          if u - l < result[i]:
            result[i] = u - l; U[i] = u; L[i] = l
    for y in countdown(h - 1, 0):
      for x in countdown(w - 1, 0):
        let i = y * w + x
        for (nx, ny) in [(x + 1, y), (x, y + 1)]:
          if nx >= w or ny >= h: continue
          let j = ny * w + nx
          let u = max(U[j], v[i])
          let l = min(L[j], v[i])
          if u - l < result[i]:
            result[i] = u - l; U[i] = u; L[i] = l
  for x in result.mitems:
    if x == Inf: x = 0

proc normalize(v: var seq[float32]) =
  var lo = Inf.float32
  var hi = -Inf.float32
  for x in v:
    lo = min(lo, x)
    hi = max(hi, x)
  let d = max(1e-6'f32, hi - lo)
  for x in v.mitems: x = (x - lo) / d

proc otsu(v: seq[float32]): float32 =
  var hist: array[64, int]
  for x in v: inc hist[clamp(int(x * 63.999), 0, 63)]
  let n = v.len.float
  var sum = 0.0
  for k in 0 ..< 64: sum += k.float * hist[k].float
  var sumB, wB = 0.0
  var best = -1.0
  for k in 0 ..< 64:
    wB += hist[k].float
    if wB == 0: continue
    let wF = n - wB
    if wF == 0: break
    sumB += k.float * hist[k].float
    let mB = sumB / wB
    let mF = (sum - sumB) / wF
    let between = wB * wF * (mB - mF) ^ 2
    if between > best:
      best = between
      result = float32((k.float + 0.5) / 64)

# ---- Select Subject ----------------------------------------------------------------------------------------

proc detailMap(lab: seq[Col]; w, h: int): seq[float32] =
  ## How much fine detail there is around each pixel (0..1): texture, and
  ## what is in focus.
  let n = w * h
  result = newSeq[float32](n)
  for y in 1 ..< h - 1:
    for x in 1 ..< w - 1:
      let i = y * w + x
      result[i] = abs(4 * lab[i][0] - lab[i - 1][0] - lab[i + 1][0] - lab[i - w][0] - lab[i + w][0])
  boxBlur(result, w, h, 4)
  var sorted = result
  sorted.sort()
  let hi = max(0.5'f32, sorted[n * 98 div 100])
  for x in result.mitems: x = min(1'f32, x / hi)

proc subjectSaliency(lab: seq[Col]; w, h: int): seq[float32] =
  ## How much each pixel stands out as the subject: far (by the least
  ## barrier, and by color) from the picture's edges -- but for edges the
  ## subject itself fills -- nearer the middle, and, when the edges are
  ## smooth (a plain or blurred background), detailed.
  let n = w * h
  let detail = detailMap(lab, w, h)
  var sideMean: array[4, Col]
  var sideDetail: array[4, float]
  var sideCount: array[4, int]
  template addTo(k, i: int) =
    for c in 0 .. 2: sideMean[k][c] += lab[i][c]
    sideDetail[k] += detail[i].float
    inc sideCount[k]
  for x in 0 ..< w:
    for t in 0 .. 1:
      addTo(0, t * w + x)
      addTo(2, (h - 1 - t) * w + x)
  for y in 0 ..< h:
    for t in 0 .. 1:
      addTo(1, y * w + w - 1 - t)
      addTo(3, y * w + t)
  for k in 0 .. 3:
    for c in 0 .. 2: sideMean[k][c] /= max(1, sideCount[k]).float32
    sideDetail[k] /= max(1, sideCount[k]).float
  var unlike: array[4, float]
  for k in 0 .. 3:
    for j in 0 .. 3:
      if j != k:
        unlike[k] += sqrt(float((sideMean[k][0] - sideMean[j][0]) ^ 2 + (sideMean[k][1] - sideMean[j][1]) ^ 2 +
                                (sideMean[k][2] - sideMean[j][2]) ^ 2)) / 3
  var sortedU = unlike
  sortedU.sort()
  var sortedD = sideDetail
  sortedD.sort()
  let edgeDetail = sortedD[0]
  let smoothEdges = edgeDetail < 0.075                # (a plain or blurred background shows)
  when defined(subjectDebug): echo "sides unlike ", unlike, " detail ", sideDetail, " smooth ", smoothEdges
  # the edges the subject fills: unlike the others, or (on smooth edges) detailed
  var dropped: array[4, bool]
  var kept = 4
  var order = [0, 1, 2, 3]
  order.sort(proc (a, b: int): int = cmp(unlike[b] + sideDetail[b] * 40, unlike[a] + sideDetail[a] * 40))
  for k in order:
    if kept <= 1: break
    let odd = unlike[k] > 18 and unlike[k] > 1.8 * sortedU[1]
    let busy = smoothEdges and sideDetail[k] > max(0.1, 2.5 * edgeDetail)
    if odd or busy:
      dropped[k] = true
      dec kept
  var seeds = newSeq[bool](n)
  let plain = max(0.06, 2.2 * edgeDetail)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      let side = if y <= 1: 0 elif x >= w - 2: 1 elif y >= h - 2: 2 elif x <= 1: 3 else: -1
      if side >= 0 and not dropped[side] and (not smoothEdges or detail[i] < plain): seeds[i] = true
  # the barrier from the edges, in each of L, a, b
  var total = newSeq[float32](n)
  for c in 0 .. 2:
    var v = newSeq[float32](n)
    for i in 0 ..< n: v[i] = lab[i][c]
    let d = mbd(v, seeds, w, h)
    for i in 0 ..< n: total[i] += d[i]
  normalize(total)
  # unlike the edges' colors
  var edgeIdx: seq[int32]
  for i in 0 ..< n:
    if seeds[i]: edgeIdx.add int32(i)
  var unlikeEdge = newSeq[float32](n)
  if edgeIdx.len > 0:
    let cl = kmeans(lab, edgeIdx, 4)
    var centers: array[4, array[3, float]]
    var cn: array[4, int]
    for i in edgeIdx:
      for c in 0 .. 2: centers[cl[i]][c] += lab[i][c]
      inc cn[cl[i]]
    for k in 0 .. 3:
      for c in 0 .. 2: centers[k][c] /= max(1, cn[k]).float
    for i in 0 ..< n:
      var best = Inf
      for k in 0 .. 3:
        if cn[k] * 50 < edgeIdx.len: continue          # (a few odd pixels of the edge)
        let d = (lab[i][0] - centers[k][0]) ^ 2 + (lab[i][1] - centers[k][1]) ^ 2 + (lab[i][2] - centers[k][2]) ^ 2
        best = min(best, d)
      unlikeEdge[i] = float32(sqrt(best))
    normalize(unlikeEdge)
  var busy = detail
  if smoothEdges:
    boxBlur(busy, w, h, 5)
    normalize(busy)
  result = newSeq[float32](n)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      let dx = (x.float / w.float - 0.5)
      let dy = (y.float / h.float - 0.5)
      let center = exp(-(dx * dx + dy * dy) / (2 * 0.32 * 0.32))
      let cue = if smoothEdges: 0.45 * total[i] + 0.25 * unlikeEdge[i] + 0.3 * busy[i]
                else: 0.6 * total[i] + 0.4 * unlikeEdge[i]
      result[i] = float32(cue * (0.35 + 0.65 * center))
  boxBlur(result, w, h, 1)
  normalize(result)

proc selectSubject*(src: Img; detail = 360): seq[uint8] =
  ## Select Subject: the main thing in the picture (what stands out from
  ## the edges, nearer the middle), its outline following the picture's
  ## edges. 0..255 per pixel of `src`.
  result = newSeq[uint8](src.w * src.h)
  if src.w < 8 or src.h < 8: return
  let (small, lab, lum) = proxyOf(src, detail)
  let w = small.w
  let h = small.h
  let n = w * h
  var sal = subjectSaliency(lab, w, h)
  # (people are what pictures are most often of: skin away from the edges
  # stands out more)
  block:
    var skin = 0
    var sk = newSeq[float32](n)
    for y in 0 ..< h:
      for x in 0 ..< w:
        let i = y * w + x
        let p = small.px[i]
        let r = rOf(p)
        let g = gOf(p)
        let b = bOf(p)
        if r > 95 and g > 40 and b > 20 and r > g and r > b and r - min(g, b) > 15 and abs(r - g) > 15:
          let border = min(min(x, w - 1 - x).float / w.float, min(y, h - 1 - y).float / h.float)
          if border > 0.04:
            sk[i] = 1
            inc skin
    if skin > n div 200 and skin < n div 2:
      boxBlur(sk, w, h, 2)
      for i in 0 ..< n: sal[i] = min(1'f32, sal[i] + 0.25'f32 * sk[i])
  let t = clamp(otsu(sal), 0.15'f32, 0.75'f32)
  var fg = newSeq[bool](n)
  var hard = newSeq[int8](n)
  for i in 0 ..< n:
    fg[i] = sal[i] > t
    if sal[i] > t + (1 - t) * 0.55: hard[i] = 1
    elif sal[i] < t * 0.25: hard[i] = -1
  grabCut(lab, w, h, fg, hard, 5)
  # the biggest part (and any nearly as big), its holes filled
  let (id, sizes) = components(fg, w, h)
  if sizes.len == 0: return
  var big = 0
  for s in sizes: big = max(big, s)
  for i in 0 ..< n:
    if fg[i] and sizes[id[i]] * 4 < big: fg[i] = false
  fillHoles(fg, w, h, big div 8)
  # a second, finer look at the edge: on a copy twice as detailed, only the
  # band round the outline found is decided again (GrabCut), what is well
  # inside or well outside held
  let fine = min(max(src.w, src.h), detail * 2)
  if fine > max(w, h) + 16:
    let (small2, lab2, lum2) = proxyOf(src, fine)
    let w2 = small2.w
    let h2 = small2.h
    var fg2 = newSeq[bool](w2 * h2)
    var hard2 = newSeq[int8](w2 * h2)
    # (the first answer, read at the finer size; the band: near its edge)
    var near = newSeq[float32](w2 * h2)
    for y in 0 ..< h2:
      let sy = min(h - 1, y * h div h2)
      for x in 0 ..< w2:
        let sx = min(w - 1, x * w div w2)
        let i = y * w2 + x
        fg2[i] = fg[sy * w + sx]
        near[i] = if fg2[i]: 1'f32 else: 0'f32
    let band = max(2, w2 div 90)
    boxBlur(near, w2, h2, band)
    for i in 0 ..< w2 * h2:
      if near[i] >= 0.999: hard2[i] = 1
      elif near[i] <= 0.001: hard2[i] = -1
    grabCut(lab2, w2, h2, fg2, hard2, 3)
    let (id2, sizes2) = components(fg2, w2, h2)
    var big2 = 0
    for sz in sizes2: big2 = max(big2, sz)
    for i in 0 ..< w2 * h2:
      if fg2[i] and sizes2[id2[i]] * 4 < big2: fg2[i] = false
    fillHoles(fg2, w2, h2, big2 div 8)
    result = maskUp(fg2, w2, h2, src, lum2); return
  result = maskUp(fg, w, h, src, lum)

# ---- Object Selection, Quick Selection ----------------------------------------------------------------------

proc cropImg(src: Img; r: Rect): Img =
  result = newImgUninit(r.w, r.h)
  for y in 0 ..< r.h:
    copyMem(addr result.px[y * r.w], unsafeAddr src.px[(r.y + y) * src.w + r.x], r.w * 4)

proc placeMask(dst: var seq[uint8]; w: int; r: Rect; m: seq[uint8]) =
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      dst[(r.y + y) * w + r.x + x] = m[y * r.w + x]

proc objectSelect*(src: Img; box: Rect; detail = 320): seq[uint8] =
  ## Object Selection: the thing a box was drawn round -- what in the box
  ## does not look like what is round it, cut along the picture's edges
  ## (GrabCut). 0..255 per pixel of `src`.
  result = newSeq[uint8](src.w * src.h)
  let b = intersect(box, rect(0, 0, src.w, src.h))
  if b.w < 4 or b.h < 4: return
  # (the box and some of what is round it: that is what is behind)
  let m = max(8, max(b.w, b.h) div 5)
  let r = intersect(rect(b.x - m, b.y - m, b.w + 2 * m, b.h + 2 * m), rect(0, 0, src.w, src.h))
  let part = cropImg(src, r)
  let (small, lab, lum) = proxyOf(part, detail)
  let w = small.w
  let h = small.h
  let n = w * h
  let kx = w / r.w
  let ky = h / r.h
  let bx0 = int((b.x - r.x).float * kx)
  let by0 = int((b.y - r.y).float * ky)
  let bx1 = min(w, int(ceil((b.x + b.w - r.x).float * kx)))
  let by1 = min(h, int(ceil((b.y + b.h - r.y).float * ky)))
  var fg = newSeq[bool](n)
  var hard = newSeq[int8](n)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let inside = x >= bx0 and x < bx1 and y >= by0 and y < by1
      fg[y * w + x] = inside
      if not inside: hard[y * w + x] = -1
  grabCut(lab, w, h, fg, hard, 6)
  # the biggest part (and any nearly as big), its holes filled
  let (id, sizes) = components(fg, w, h)
  if sizes.len == 0: return
  var big = 0
  for s in sizes: big = max(big, s)
  for i in 0 ..< n:
    if fg[i] and sizes[id[i]] * 6 < big: fg[i] = false
  fillHoles(fg, w, h, big div 6)
  let mk = maskUp(fg, w, h, part, lum)
  result.placeMask(src.w, r, mk)

proc quickSelect*(src: Img; seeds: seq[uint8]; area: Rect; detail = 300): seq[uint8] =
  ## Quick Selection: what was painted over (`seeds`, as big as `src`) grown
  ## to the edges round it, within `area` (where the brush went, widened).
  ## 0..255 per pixel of `src`.
  result = newSeq[uint8](src.w * src.h)
  let r = intersect(area, rect(0, 0, src.w, src.h))
  if r.w < 4 or r.h < 4: return
  let part = cropImg(src, r)
  let (small, lab, lum) = proxyOf(part, detail)
  let w = small.w
  let h = small.h
  let n = w * h
  var fg = newSeq[bool](n)
  var hard = newSeq[int8](n)
  var any = false
  for y in 0 ..< h:
    for x in 0 ..< w:
      # (the seed under this small pixel: any in its square)
      let sx0 = r.x + x * r.w div w
      let sy0 = r.y + y * r.h div h
      let sx1 = max(sx0 + 1, r.x + (x + 1) * r.w div w)
      let sy1 = max(sy0 + 1, r.y + (y + 1) * r.h div h)
      var seed = false
      var yy = sy0
      while yy < sy1 and not seed:
        for xx in sx0 ..< sx1:
          if seeds[yy * src.w + xx] > 127:
            seed = true
            break
        inc yy
      let i = y * w + x
      if seed:
        hard[i] = 1
        fg[i] = true
        any = true
      elif (x == 0 and r.x > 0) or (y == 0 and r.y > 0) or (x == w - 1 and r.x + r.w < src.w) or
           (y == h - 1 and r.y + r.h < src.h):
        hard[i] = -1                       # (the area's edge, not the picture's: behind)
  if not any: return
  # (what looks like the seeds, at the start)
  var seedLab: array[3, float]
  var cnt = 0
  for i in 0 ..< n:
    if hard[i] == 1:
      for a in 0 .. 2: seedLab[a] += lab[i][a]
      inc cnt
  for a in 0 .. 2: seedLab[a] /= cnt.float
  for i in 0 ..< n:
    if hard[i] == 0:
      let dd = (lab[i][0] - seedLab[0]) ^ 2 + (lab[i][1] - seedLab[1]) ^ 2 + (lab[i][2] - seedLab[2]) ^ 2
      fg[i] = dd < 18.0 * 18.0
  grabCut(lab, w, h, fg, hard, 4)
  # only the parts the brush touched
  let (id, sizes) = components(fg, w, h)
  var touched = newSeq[bool](sizes.len)
  for i in 0 ..< n:
    if hard[i] == 1 and id[i] >= 0: touched[id[i]] = true
  for i in 0 ..< n:
    if fg[i] and not touched[id[i]]: fg[i] = false
  fillHoles(fg, w, h, n div 20)
  let mk = maskUp(fg, w, h, part, lum)
  result.placeMask(src.w, r, mk)

proc guidedColor(src: Img; p: var seq[float32]; r: int; eps: float32) =
  ## (the guided filter with the picture's colors as its guide -- He, Sun
  ## and Tang's -- an edge between two colors of the same lightness found
  ## too; near the mask's edge only)
  let w = src.w
  let h = src.h
  let n = w * h
  var I: array[3, seq[float32]]
  for c in 0 .. 2: I[c] = newSeq[float32](n)
  for i in 0 ..< n:
    let px = src.px[i]
    I[0][i] = rOf(px).float32 / 255
    I[1][i] = gOf(px).float32 / 255
    I[2][i] = bOf(px).float32 / 255
  var mI: array[3, seq[float32]]
  var mIp: array[3, seq[float32]]
  for c in 0 .. 2:
    mI[c] = I[c]
    boxBlur(mI[c], w, h, r)
    mIp[c] = newSeq[float32](n)
    for i in 0 ..< n: mIp[c][i] = I[c][i] * p[i]
    boxBlur(mIp[c], w, h, r)
  var mp = p
  boxBlur(mp, w, h, r)
  const pairs = [(0, 0), (0, 1), (0, 2), (1, 1), (1, 2), (2, 2)]
  var cv: array[6, seq[float32]]
  for k, (a, b) in pairs:
    cv[k] = newSeq[float32](n)
    for i in 0 ..< n: cv[k][i] = I[a][i] * I[b][i]
    boxBlur(cv[k], w, h, r)
  var A: array[3, seq[float32]]
  for c in 0 .. 2: A[c] = newSeq[float32](n)
  var B = newSeq[float32](n)
  for i in 0 ..< n:
    let m0 = mI[0][i]
    let m1 = mI[1][i]
    let m2 = mI[2][i]
    let s00 = cv[0][i] - m0 * m0 + eps
    let s01 = cv[1][i] - m0 * m1
    let s02 = cv[2][i] - m0 * m2
    let s11 = cv[3][i] - m1 * m1 + eps
    let s12 = cv[4][i] - m1 * m2
    let s22 = cv[5][i] - m2 * m2 + eps
    let c0 = mIp[0][i] - m0 * mp[i]
    let c1 = mIp[1][i] - m1 * mp[i]
    let c2 = mIp[2][i] - m2 * mp[i]
    # (the 3 x 3 covariance inverted: its cofactors over its determinant)
    let i00 = s11 * s22 - s12 * s12
    let i01 = s02 * s12 - s01 * s22
    let i02 = s01 * s12 - s02 * s11
    let i11 = s00 * s22 - s02 * s02
    let i12 = s01 * s02 - s00 * s12
    let i22 = s00 * s11 - s01 * s01
    let det = s00 * i00 + s01 * i01 + s02 * i02
    if abs(det) < 1e-12:
      A[0][i] = 0; A[1][i] = 0; A[2][i] = 0
      B[i] = mp[i]
      continue
    let a0 = (i00 * c0 + i01 * c1 + i02 * c2) / det
    let a1 = (i01 * c0 + i11 * c1 + i12 * c2) / det
    let a2 = (i02 * c0 + i12 * c1 + i22 * c2) / det
    A[0][i] = a0; A[1][i] = a1; A[2][i] = a2
    B[i] = mp[i] - a0 * m0 - a1 * m1 - a2 * m2
  for c in 0 .. 2: boxBlur(A[c], w, h, r)
  boxBlur(B, w, h, r)
  var near = p
  boxBlur(near, w, h, r)
  for i in 0 ..< n:
    let q = clamp(A[0][i] * I[0][i] + A[1][i] * I[1][i] + A[2][i] * I[2][i] + B[i], 0, 1)
    let k = if near[i] > 0.02 and near[i] < 0.98: 1'f32 else: 0'f32
    p[i] = p[i] * (1 - k) + q * k

proc refineEdge*(src: Img; mask: seq[uint8]; radius: float; smooth = 0; feather = 0.0; contrast = 0;
                 shift = 0; smart = true; colorAware = false): seq[uint8] =
  ## Select and Mask: a mask's edge made to follow the picture -- in a band
  ## `radius` pixels wide (Smart Radius: wider where the edge is soft, hair
  ## and fur) -- then smoothed, feathered, made harder (`contrast` %) and
  ## moved in or out (`shift` %). `colorAware`: guided by the picture's
  ## colors, not only its lightness (hair against a background of another
  ## color as light; pictures up to 12 megapixels). 0..255 per pixel.
  let w = src.w
  let h = src.h
  let n = w * h
  result = mask
  if n == 0 or mask.len != n: return
  # the band: the mask's edge, widened
  var edge = newSeq[float32](n)
  var lum = newSeq[float32](n)
  var p = newSeq[float32](n)
  for i in 0 ..< n:
    let c = src.px[i]
    lum[i] = (0.299'f32 * rOf(c).float32 + 0.587'f32 * gOf(c).float32 + 0.114'f32 * bOf(c).float32) / 255
    p[i] = mask[i].float32 / 255
  if radius > 0.5 and colorAware and n <= 12_000_000:
    guidedColor(src, p, max(1, int(round(radius))), if smart: 0.0004'f32 else: 0.0025'f32)
  elif radius > 0.5:
    # (the guided filter, with the picture's lightness as its guide: the edge
    # follows the picture's within the radius)
    let r = max(1, int(round(radius)))
    let eps = if smart: 0.0004'f32 else: 0.0025'f32
    var mI = lum
    var mP = p
    var mIP = newSeq[float32](n)
    var mII = newSeq[float32](n)
    for i in 0 ..< n:
      mIP[i] = lum[i] * p[i]
      mII[i] = lum[i] * lum[i]
    boxBlur(mI, w, h, r); boxBlur(mP, w, h, r); boxBlur(mIP, w, h, r); boxBlur(mII, w, h, r)
    var a = newSeq[float32](n)
    var b = newSeq[float32](n)
    for i in 0 ..< n:
      let v = mII[i] - mI[i] * mI[i]
      a[i] = (mIP[i] - mI[i] * mP[i]) / (v + eps)
      b[i] = mP[i] - a[i] * mI[i]
    boxBlur(a, w, h, r); boxBlur(b, w, h, r)
    # only near the edge: far inside and far outside stay as they were
    var near = p
    boxBlur(near, w, h, r)
    for i in 0 ..< n:
      let q = clamp(a[i] * lum[i] + b[i], 0, 1)
      let k = if near[i] > 0.02 and near[i] < 0.98: 1'f32 else: 0'f32
      p[i] = p[i] * (1 - k) + q * k
  if smooth > 0:
    var q = p
    boxBlur(q, w, h, smooth)
    for i in 0 ..< n: p[i] = if q[i] >= 0.5: max(p[i], q[i]) else: min(p[i], q[i])
    for i in 0 ..< n: p[i] = q[i] * 0.5 + p[i] * 0.5
  if feather > 0.05:
    var g = newSeq[uint8](n)
    for i in 0 ..< n: g[i] = uint8(clamp(p[i] * 255 + 0.5, 0, 255))
    blurMask(g, w, h, feather)
    for i in 0 ..< n: p[i] = g[i].float32 / 255
  let sh = shift.float32 / 200
  let k = 1 + contrast.float32 / 25
  for i in 0 ..< n:
    var v = p[i] + sh
    if contrast > 0: v = (v - 0.5) * k + 0.5
    result[i] = uint8(clamp(v * 255 + 0.5, 0, 255))

proc refineHair*(src: Img; mask: seq[uint8]): seq[uint8] =
  ## Refine Hair: where the edge of a selection is fine detail (hair, fur,
  ## feathers, twigs), its mask made to follow each strand -- the guided
  ## filter over a wide radius there -- while plain edges stay as sharp as
  ## they were. 0..255 per pixel.
  let w = src.w
  let h = src.h
  let n = w * h
  result = mask
  if n == 0 or mask.len != n: return
  let r = max(4, min(w, h) div 80)
  let wide = refineEdge(src, mask, r.float, smart = true)
  # (fine detail: the picture's lightness changes a lot within a few pixels)
  var mI = newSeq[float32](n)
  var mII = newSeq[float32](n)
  for i in 0 ..< n:
    let c = src.px[i]
    let l = (0.299'f32 * rOf(c).float32 + 0.587'f32 * gOf(c).float32 + 0.114'f32 * bOf(c).float32) / 255
    mI[i] = l
    mII[i] = l * l
  boxBlur(mI, w, h, 2)
  boxBlur(mII, w, h, 2)
  for i in 0 ..< n:
    let v = max(0'f32, mII[i] - mI[i] * mI[i])
    let k = clamp(v / 0.004'f32, 0, 1)
    result[i] = uint8(clamp(mask[i].float32 * (1 - k) + wide[i].float32 * k + 0.5, 0, 255))

# ---- Object Finder: the things in a picture ----------------------------------------------------------------
#
# The picture cut in regions that hang together (Felzenszwalb and
# Huttenlocher's graph segmentation, on a small copy in Lab): the region the
# mouse is over is shown, a click selects the thing in its box (GrabCut).

type
  Segments* = object
    ## A picture in regions: `id` for each pixel of a `w` x `h` copy.
    w*, h*: int               ## the copy's size
    id*: seq[int32]           ## each pixel's region (an index of `boxes`)
    boxes*: seq[Rect]         ## each region's box, in the copy's pixels
    srcW*, srcH*: int         ## the picture's size

proc segment*(src: Img; detail = 240; k = 900.0; minSize = 0): Segments =
  ## The regions of `src` (on a copy at most `detail` pixels on a side):
  ## bigger `k`, bigger regions.
  result.srcW = src.w
  result.srcH = src.h
  if src.w < 4 or src.h < 4: return
  let (small, lab, _) = proxyOf(src, detail)
  let w = small.w
  let h = small.h
  let n = w * h
  result.w = w
  result.h = h
  # (the edges between neighbors, weighed by how different their colors are)
  var edges = newSeqOfCap[(float32, int32, int32)](n * 4)
  template dist(a, b: int): float32 =
    sqrt((lab[a][0] - lab[b][0]) * (lab[a][0] - lab[b][0]) + (lab[a][1] - lab[b][1]) * (lab[a][1] - lab[b][1]) +
         (lab[a][2] - lab[b][2]) * (lab[a][2] - lab[b][2]))
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      if x + 1 < w: edges.add (dist(i, i + 1), int32(i), int32(i + 1))
      if y + 1 < h: edges.add (dist(i, i + w), int32(i), int32(i + w))
      if x + 1 < w and y + 1 < h: edges.add (dist(i, i + w + 1), int32(i), int32(i + w + 1))
      if x > 0 and y + 1 < h: edges.add (dist(i, i + w - 1), int32(i), int32(i + w - 1))
  edges.sort(proc (a, b: (float32, int32, int32)): int = cmp(a[0], b[0]))
  var parent = newSeq[int32](n)
  var size = newSeq[int32](n)
  var inner = newSeq[float32](n)
  for i in 0 ..< n:
    parent[i] = int32(i)
    size[i] = 1
  proc find(parent: var seq[int32]; i: int32): int32 =
    var r = i
    while parent[r] != r: r = parent[r]
    var j = i
    while parent[j] != r:
      let nx = parent[j]
      parent[j] = r
      j = nx
    r
  let kk = float32(k)
  for (wt, a, b) in edges:
    let ra = find(parent, a)
    let rb = find(parent, b)
    if ra == rb: continue
    if wt <= min(inner[ra] + kk / size[ra].float32, inner[rb] + kk / size[rb].float32):
      let (big, sm) = if size[ra] >= size[rb]: (ra, rb) else: (rb, ra)
      parent[sm] = big
      size[big] += size[sm]
      inner[big] = max(wt, max(inner[big], inner[sm]))
  # (small bits joined to a neighbor)
  let least = if minSize > 0: minSize else: max(20, n div 400)
  for (wt, a, b) in edges:
    let ra = find(parent, a)
    let rb = find(parent, b)
    if ra != rb and (size[ra] < least or size[rb] < least):
      let (big, sm) = if size[ra] >= size[rb]: (ra, rb) else: (rb, ra)
      parent[sm] = big
      size[big] += size[sm]
  # numbered from 0, with their boxes
  var num = newSeq[int32](n)
  for i in 0 ..< n: num[i] = -1
  result.id = newSeq[int32](n)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      let r = find(parent, int32(i))
      if num[r] < 0:
        num[r] = int32(result.boxes.len)
        result.boxes.add rect(x, y, 1, 1)
      let k2 = num[r]
      result.id[i] = k2
      let b = result.boxes[k2]
      let x0 = min(b.x, x)
      let y0 = min(b.y, y)
      result.boxes[k2] = rect(x0, y0, max(b.x + b.w, x + 1) - x0, max(b.y + b.h, y + 1) - y0)

proc regionAt*(s: Segments; x, y: float): int =
  ## The region at picture point `x`, `y` (-1 outside).
  if s.w <= 0 or x < 0 or y < 0 or x >= s.srcW.float or y >= s.srcH.float: return -1
  let sx = clamp(int(x * s.w.float / s.srcW.float), 0, s.w - 1)
  let sy = clamp(int(y * s.h.float / s.srcH.float), 0, s.h - 1)
  int(s.id[sy * s.w + sx])

proc regionBox*(s: Segments; k: int): Rect =
  ## Region `k`'s box in the picture's pixels.
  if k < 0 or k >= s.boxes.len: return
  let b = s.boxes[k]
  let x0 = b.x * s.srcW div s.w
  let y0 = b.y * s.srcH div s.h
  rect(x0, y0, max(1, (b.x + b.w) * s.srcW div s.w - x0), max(1, (b.y + b.h) * s.srcH div s.h - y0))

proc findObject*(src: Img; s: Segments; k: int): seq[uint8] =
  ## The thing region `k` is part of: GrabCut in its box (a little wider).
  ## 0..255 per pixel of `src`.
  let b = s.regionBox(k)
  if b.w <= 0: return newSeq[uint8](src.w * src.h)
  let m = max(4, max(b.w, b.h) div 12)
  objectSelect(src, rect(b.x - m, b.y - m, b.w + 2 * m, b.h + 2 * m))

proc decontaminate*(src: var Img; mask: seq[uint8]; amount = 100) =
  ## Decontaminate Colors: at the soft edge of a mask, the colors of what is
  ## behind taken out -- each edge pixel given the color of the nearest
  ## pixel well inside.
  let w = src.w
  let h = src.h
  if mask.len != w * h: return
  var col = src.px
  var known = newSeq[bool](w * h)
  for i in 0 ..< w * h: known[i] = mask[i] >= 230
  # (the inside's colors spread outward, a ring at a time)
  for pass in 0 ..< 24:
    var grew = false
    var nk = known
    for y in 0 ..< h:
      for x in 0 ..< w:
        let i = y * w + x
        if known[i] or mask[i] == 0: continue
        var r, g, b, c = 0
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
          if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
          let j = ny * w + nx
          if known[j]:
            r += rOf(col[j]); g += gOf(col[j]); b += bOf(col[j]); inc c
        if c > 0:
          col[i] = argb(aOf(src.px[i]), r div c, g div c, b div c)
          nk[i] = true
          grew = true
    known = nk
    if not grew: break
  for i in 0 ..< w * h:
    let m = int(mask[i])
    if m > 0 and m < 230:
      let t = amount.float / 100 * (1 - m / 230)
      src.px[i] = (src.px[i] and 0xFF000000'u32) or (mix(src.px[i], col[i], t) and 0xFFFFFF'u32)

proc objectSelect*(d: Doc; box: Rect; merged = true): seq[uint8] =
  ## Object Selection on the image as it looks (or the current layer).
  d.updateComposite()
  let src = if merged: Img(w: d.w, h: d.h, px: d.compCopy) else: Img(w: d.w, h: d.h, px: d.layer.px)
  objectSelect(src, box)

proc quickSelect*(d: Doc; seeds: seq[uint8]; area: Rect; merged = true): seq[uint8] =
  ## Quick Selection on the image as it looks (or the current layer).
  d.updateComposite()
  let src = if merged: Img(w: d.w, h: d.h, px: d.compCopy) else: Img(w: d.w, h: d.h, px: d.layer.px)
  quickSelect(src, seeds, area)

# ---- Select Sky -------------------------------------------------------------------------------------------

proc skyLikelihood(lab: seq[Col]; w, h: int): tuple[p, color: seq[float32]] =
  ## How much each pixel looks like sky (`p`), and by its color alone.
  let n = w * h
  # how busy the picture is around each pixel
  var tex = newSeq[float32](n)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      let gx = lab[min(x + 1, w - 1) + y * w][0] - lab[max(x - 1, 0) + y * w][0]
      let gy = lab[min(y + 1, h - 1) * w + x][0] - lab[max(y - 1, 0) * w + x][0]
      tex[i] = sqrt(gx * gx + gy * gy)
  boxBlur(tex, w, h, 2)
  result.p = newSeq[float32](n)
  result.color = newSeq[float32](n)
  for y in 0 ..< h:
    let pos = y / h
    for x in 0 ..< w:
      let i = y * w + x
      let L = lab[i][0].float
      let a = lab[i][1].float
      let b = lab[i][2].float
      let chroma = sqrt(a * a + b * b)
      # blue (by day or at dusk), overcast (bright, nearly gray), at sunset (warm, high up)
      let blue = clamp((-b - 4) / 16, 0.0, 1.0) * clamp((L - 4) / 14, 0.0, 1.0)
      let white = clamp((L - 80) / 10, 0.0, 1.0) * clamp(1 - chroma / 14, 0.0, 1.0)
      let warm = clamp((L - 35) / 25, 0.0, 1.0) * clamp((a + b - 20) / 40, 0.0, 1.0) * clamp(1 - pos * 2, 0.0, 1.0)
      let color = max(blue, max(white * 0.9, warm * 0.7))
      let smooth = clamp(1 - tex[i].float / 10, 0.0, 1.0)
      result.p[i] = float32(color * smooth * smooth * clamp(1.3 - pos, 0.0, 1.0))
      result.color[i] = float32(color)

proc selectSky*(src: Img; detail = 360): seq[uint8] =
  ## Select Sky: the sky (blue, overcast or at sunset: light, smooth, from
  ## the top), its outline following the picture's -- trees and roofs left
  ## out. 0..255 per pixel of `src`; all 0 when there is no sky.
  result = newSeq[uint8](src.w * src.h)
  if src.w < 8 or src.h < 8: return
  let (small, lab, lum) = proxyOf(src, detail)
  let w = small.w
  let h = small.h
  let n = w * h
  let (p, skyColor) = skyLikelihood(lab, w, h)
  # seeds: the sky-like pixels of the top
  var seeds = newSeq[bool](n)
  var top = 0
  for y in 0 .. min(1, h - 1):
    for x in 0 ..< w:
      if p[y * w + x] > 0.35:
        seeds[y * w + x] = true
        inc top
  if top * 100 < 2 * w * 15: return             # (too little of the top looks like sky)
  # what looks like sky and is joined to them
  var fg = newSeq[bool](n)
  var stack: seq[int]
  for i in 0 ..< n:
    if seeds[i]:
      fg[i] = true
      stack.add i
  while stack.len > 0:
    let i = stack.pop()
    let x = i mod w
    let y = i div w
    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
      if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
      let j = ny * w + nx
      if not fg[j] and p[j] > 0.12:
        fg[j] = true
        stack.add j
  var hard = newSeq[int8](n)
  for i in 0 ..< n:
    if fg[i] and p[i] > 0.5: hard[i] = 1
    elif skyColor[i] < 0.03: hard[i] = -1               # (no sky is that color)
  grabCut(lab, w, h, fg, hard, 4)
  # the parts that reach the seeds
  let (id, sizes) = components(fg, w, h)
  var keep = newSeq[bool](sizes.len)
  for i in 0 ..< n:
    if seeds[i] and fg[i]: keep[id[i]] = true
  for i in 0 ..< n:
    if fg[i] and not keep[id[i]]: fg[i] = false
  fillHoles(fg, w, h, n div 2000)
  result = maskUp(fg, w, h, src, lum)

# ---- on a document: the tools ----------------------------------------------------------------------------

proc region(d: Doc; r: Rect; margin: int): Rect =
  d.clip(rect(r.x - margin, r.y - margin, r.w + 2 * margin, r.h + 2 * margin))

proc layerImg(d: Doc; L: Layer; r: Rect; original = false): Img =
  ## `r` of `L` (as it was when the step began, with `original`).
  result = newImg(r.w, r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      result.px[y * r.w + x] = if original: d.original(L, r.x + x, r.y + y)
                               else: L.px[(r.y + y) * d.w + r.x + x]

proc putBack(d: Doc; L: Layer; r: Rect; before, after: Img; amount: openArray[uint8]) =
  ## `after` into `L` in `r`, by `amount` (r's size), over `before`; the
  ## selection, the channels edited and the alpha kept as painting keeps them.
  d.touch(L, r)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      let j = y * r.w + x
      let k = int(amount[j])
      let i = (r.y + y) * d.w + r.x + x
      if k == 0:
        L.px[i] = before.px[j]
        continue
      let a = after.px[j]
      let b = before.px[j]
      let mixed = (b and 0xFF000000'u32) or (mix(b, a, k / 255) and 0xFFFFFF'u32)
      L.px[i] = d.applyAt(L, i, b, mixed, 255)
  inc L.ver
  d.markDirty(r)

proc contentAwareFill*(d: Doc; seed = 1) =
  ## Edit > Fill with Content-Aware: the selection made again from what is
  ## around it (on the current layer; an undo step must be open).
  if not d.hasSelection: return
  let L = d.layer
  let sb = d.selBounds
  if sb.w <= 0 or sb.h <= 0: return
  let r = d.region(sb, max(40, max(sb.w, sb.h)))
  let src = d.layerImg(L, r)
  var hole = newSeq[uint8](r.w * r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w: hole[y * r.w + x] = uint8(d.selAt((r.y + y) * d.w + r.x + x))
  let filled = contentAwareFill(src, hole, seed)
  d.putBack(L, r, src, filled, hole)

type SpotHealKind* = enum
  ## The Spot Healing Brush's Type, as Photoshop's.
  shContentAware = "Content-Aware",    ## made up from what is around (the best for most)
  shCreateTexture = "Create Texture",  ## a texture woven from what is around, then fitted in
  shProximity = "Proximity Match"      ## the nearest place alike beside it, copied in and fitted

proc textureFor(src: Img; hole: openArray[uint8]; seed: int): Img =
  ## (the hole filled with pieces of what is around it, at random: a
  ## texture to heal with)
  result = src
  let w = src.w
  let h = src.h
  var outside: seq[int]
  for i in 0 ..< w * h:
    if hole[i] == 0: outside.add i
  if outside.len == 0: return
  const B = 6
  var st = uint32(seed) * 2654435761'u32 + 1
  template rnd(): int =
    st = st xor (st shl 13); st = st xor (st shr 17); st = st xor (st shl 5)
    int(st and 0x7FFFFFFF'u32)
  var by = 0
  while by < h:
    var bx = 0
    while bx < w:
      var need = false
      for y in by ..< min(h, by + B):
        for x in bx ..< min(w, bx + B):
          if hole[y * w + x] > 0: need = true
      if need:
        # (a block from outside the hole, all of it outside)
        var sx, sy = 0
        for tries in 0 ..< 40:
          let c = outside[rnd() mod outside.len]
          sx = c mod w - B div 2
          sy = c div w - B div 2
          if sx < 0 or sy < 0 or sx + B > w or sy + B > h: continue
          var ok = true
          for y in 0 ..< B:
            for x in 0 ..< B:
              if hole[(sy + y) * w + sx + x] > 0:
                ok = false
          if ok: break
        for y in by ..< min(h, by + B):
          for x in bx ..< min(w, bx + B):
            if hole[y * w + x] > 0:
              result.px[y * w + x] = src.px[clamp(sy + y - by, 0, h - 1) * w + clamp(sx + x - bx, 0, w - 1)]
      bx += B
    by += B

proc proximityFor(src: Img; hole: openArray[uint8]; area: Rect): Img =
  ## (the hole filled from the place beside it -- of eight, at the hole's
  ## size away -- whose edge is most like the hole's own edge)
  result = src
  let w = src.w
  let h = src.h
  # the ring: just outside the hole
  var ring: seq[int]
  for y in 0 ..< h:
    for x in 0 ..< w:
      if hole[y * w + x] > 0: continue
      var near = false
      for (dx, dy) in [(-2, 0), (2, 0), (0, -2), (0, 2)]:
        let nx = x + dx
        let ny = y + dy
        if nx >= 0 and ny >= 0 and nx < w and ny < h and hole[ny * w + nx] > 0: near = true
      if near: ring.add y * w + x
  if ring.len == 0: return
  let step = max(area.w, area.h) + 4
  var best = Inf
  var bdx, bdy = 0
  for (ux, uy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1)]:
    let dx = ux * step
    let dy = uy * step
    var err = 0.0
    var n = 0
    for i in ring:
      let x = i mod w + dx
      let y = i div w + dy
      if x < 0 or y < 0 or x >= w or y >= h: continue
      let a = src.px[i]
      let b = src.px[y * w + x]
      let dr = rOf(a) - rOf(b)
      let dg = gOf(a) - gOf(b)
      let db = bOf(a) - bOf(b)
      err += float(dr * dr + dg * dg + db * db)
      inc n
    if n * 2 < ring.len: continue
    let e = err / n.float
    if e < best:
      best = e
      bdx = dx
      bdy = dy
  for y in 0 ..< h:
    for x in 0 ..< w:
      if hole[y * w + x] > 0:
        result.px[y * w + x] = src.px[clamp(y + bdy, 0, h - 1) * w + clamp(x + bdx, 0, w - 1)]

proc spotHeal*(s: Stroke; seed = 1; kind = shContentAware) =
  ## The Spot Healing Brush: where the stroke went (painted to show it),
  ## made again from what is around it (`kind`: as its Type says). Call
  ## before `endStroke`; the step is still open.
  let d = s.strokeDoc
  let L = s.strokeLayer
  var area = rect(d.w, d.h, 0, 0)
  var top = 0
  var x0 = d.w
  var y0 = d.h
  var x1 = -1
  var y1 = -1
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      let c = s.coverage(y * d.w + x)
      if c > 0:
        top = max(top, c)
        x0 = min(x0, x); x1 = max(x1, x)
        y0 = min(y0, y); y1 = max(y1, y)
  if x1 < 0: return
  area = rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
  let r = d.region(area, max(24, max(area.w, area.h)))
  let src = d.layerImg(L, r, original = true)
  var hole = newSeq[uint8](r.w * r.h)
  var amount = newSeq[uint8](r.w * r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      let i = (r.y + y) * d.w + r.x + x
      let c = s.coverage(i) * 255 div max(1, top)
      let sel = d.selAt(i)
      amount[y * r.w + x] = uint8(min(255, c * 2) * sel div 255)
      if c > 20: hole[y * r.w + x] = 255
  let filled = case kind
               of shContentAware: contentAwareFill(src, hole, seed)
               of shCreateTexture: heal(src, textureFor(src, hole, seed), hole)
               of shProximity:
                 heal(src, proximityFor(src, hole, rect(area.x - r.x, area.y - r.y, area.w, area.h)), hole)
  d.putBack(L, r, src, filled, amount)

proc dilate(m: var seq[uint8]; w, h, r: int) =
  ## (a mask grown by `r` pixels: a square around each)
  if r <= 0: return
  var tmp = newSeq[uint8](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      var v = 0'u8
      for xx in max(0, x - r) .. min(w - 1, x + r): v = max(v, m[y * w + xx])
      tmp[y * w + x] = v
  for y in 0 ..< h:
    for x in 0 ..< w:
      var v = 0'u8
      for yy in max(0, y - r) .. min(h - 1, y + r): v = max(v, tmp[yy * w + x])
      m[y * w + x] = v

proc removeStroke*(s: Stroke; seed = 1) =
  ## The Remove tool: what the stroke went over taken away -- made again from
  ## a wide area round it, all of it (a little past the stroke's edge, its
  ## seam softened). Call before `endStroke`; the step is still open.
  let d = s.strokeDoc
  let L = s.strokeLayer
  var x0 = d.w
  var y0 = d.h
  var x1 = -1
  var y1 = -1
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      if s.coverage(y * d.w + x) > 0:
        x0 = min(x0, x); x1 = max(x1, x)
        y0 = min(y0, y); y1 = max(y1, y)
  if x1 < 0: return
  let area = rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
  let grow = max(2, max(area.w, area.h) div 40)
  let r = d.region(area, max(48, max(area.w, area.h)))
  let src = d.layerImg(L, r, original = true)
  var hole = newSeq[uint8](r.w * r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      if s.coverage((r.y + y) * d.w + r.x + x) > 0: hole[y * r.w + x] = 255
  dilate(hole, r.w, r.h, grow)
  let filled = contentAwareFill(src, hole, seed)
  # (the seam: the edge of the hole softened over a few pixels)
  var amount = hole
  var soft = newSeq[uint8](r.w * r.h)
  for i in 0 ..< hole.len: soft[i] = hole[i]
  dilate(soft, r.w, r.h, 2)
  for i in 0 ..< amount.len:
    let a = if hole[i] > 0: 255 elif soft[i] > 0: 128 else: 0
    amount[i] = uint8(a * d.selAt((r.y + i div r.w) * d.w + r.x + i mod r.w) div 255)
  d.putBack(L, r, src, filled, amount)

proc contentAwareMove*(d: Doc; dx, dy: int; extend = false; seed = 1) =
  ## Content-Aware Move: the selection's pixels moved `dx`, `dy` and made to
  ## fit where they land (its light and color); where they were made again
  ## from round it -- or, to Extend, left as it was (an undo step must be
  ## open; the selection moves too).
  if not d.hasSelection or (dx == 0 and dy == 0): return
  let L = d.layer
  let sb = d.selBounds
  if sb.w <= 0 or sb.h <= 0: return
  # what moves (before anything changes)
  let moved = L.px
  let sel = d.sel
  if not extend:
    let r = d.region(sb, max(40, max(sb.w, sb.h)))
    let src = d.layerImg(L, r)
    var hole = newSeq[uint8](r.w * r.h)
    for y in 0 ..< r.h:
      for x in 0 ..< r.w: hole[y * r.w + x] = sel[(r.y + y) * d.w + r.x + x]
    dilate(hole, r.w, r.h, 2)
    let filled = contentAwareFill(src, hole, seed)
    d.putBack(L, r, src, filled, hole)
  # the selection, moved (where it lands is what changes now)
  d.touchSel()
  var ns = newSeq[uint8](d.w * d.h)
  for y in 0 ..< d.h:
    let sy = y - dy
    if sy < 0 or sy >= d.h: continue
    for x in 0 ..< d.w:
      let sx = x - dx
      if sx >= 0 and sx < d.w: ns[y * d.w + x] = sel[sy * d.w + sx]
  d.sel = ns
  inc d.selVer
  # where it lands: healed in (the moved pixels with the light and color there)
  let target = d.clip(rect(sb.x + dx, sb.y + dy, sb.w, sb.h))
  if target.w > 0 and target.h > 0:
    let r = d.region(target, 3)
    let dst = d.layerImg(L, r)
    var src = newImg(r.w, r.h)
    var mask = newSeq[uint8](r.w * r.h)
    for y in 0 ..< r.h:
      for x in 0 ..< r.w:
        let sx = r.x + x - dx
        let sy = r.y + y - dy
        if sx >= 0 and sy >= 0 and sx < d.w and sy < d.h:
          src.px[y * r.w + x] = moved[sy * d.w + sx]
          mask[y * r.w + x] = sel[sy * d.w + sx]
        else: src.px[y * r.w + x] = dst.px[y * r.w + x]
    let healed = heal(dst, src, mask)
    var all = newSeq[uint8](r.w * r.h)
    for v in all.mitems: v = 255
    d.putBack(L, r, dst, healed, all)

proc healStroke*(s: Stroke) =
  ## The Healing Brush: after a stroke of the Rubber Stamp (cloning), what
  ## it copied made to take on the light and color of where it went. Call
  ## before `endStroke`.
  let d = s.strokeDoc
  let L = s.strokeLayer
  var x0 = d.w
  var y0 = d.h
  var x1 = -1
  var y1 = -1
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      if s.coverage(y * d.w + x) > 0:
        x0 = min(x0, x); x1 = max(x1, x)
        y0 = min(y0, y); y1 = max(y1, y)
  if x1 < 0: return
  let r = d.region(rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1), 3)
  let (ox, oy) = s.stampOffset
  let dst = d.layerImg(L, r, original = true)
  var src = newImg(r.w, r.h)
  var mask = newSeq[uint8](r.w * r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      let sx = clamp(int(floor(float(r.x + x) + ox)), 0, d.w - 1)
      let sy = clamp(int(floor(float(r.y + y) + oy)), 0, d.h - 1)
      src.px[y * r.w + x] = d.original(L, sx, sy)
      let i = (r.y + y) * d.w + r.x + x
      mask[y * r.w + x] = uint8(min(255, s.coverage(i) * 255 div 65535) * d.selAt(i) div 255)
  let healed = heal(dst, src, mask)
  var all = newSeq[uint8](r.w * r.h)
  for v in all.mitems: v = 255
  d.putBack(L, r, dst, healed, all)

proc patch*(d: Doc; dx, dy: int; destination = false; transparent = false; contentAware = false;
            structure = 4; color = 0) =
  ## The Patch: the selection given the texture of the place `dx`, `dy`
  ## away, with the light and color of its own surroundings (Source); or,
  ## `destination`, what is selected copied there and fitted in. `transparent`:
  ## the patch's texture over what is there, half and half. `contentAware`
  ## (with `structure` 1..7: how much of the patch's own look is kept, and
  ## `color` 0..10: how much its colors are blended): as Photoshop's
  ## Content-Aware patch. An undo step must be open.
  if not d.hasSelection: return
  let L = d.layer
  let sb = d.selBounds
  if sb.w <= 0 or sb.h <= 0: return
  # (Destination: the patch goes where it was dragged -- its place and the
  # selection moved there)
  let place = if destination: rect(sb.x + dx, sb.y + dy, sb.w, sb.h) else: sb
  let ox = if destination: -dx else: dx
  let oy = if destination: -dy else: dy
  let r = d.region(place, 3)
  if r.w <= 0 or r.h <= 0: return
  let dst = d.layerImg(L, r)
  var src = newImg(r.w, r.h)
  var mask = newSeq[uint8](r.w * r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      let sx = clamp(r.x + x + ox, 0, d.w - 1)
      let sy = clamp(r.y + y + oy, 0, d.h - 1)
      src.px[y * r.w + x] = L.px[sy * d.w + sx]
      let mx = r.x + x - (if destination: dx else: 0)
      let my = r.y + y - (if destination: dy else: 0)
      mask[y * r.w + x] = if mx < 0 or my < 0 or mx >= d.w or my >= d.h: 0'u8
                          else: uint8(d.selAt(my * d.w + mx))
  var healed = heal(dst, src, mask)
  if contentAware:
    # (more of the patch as it is with more Structure; its colors blended
    # with more Color)
    let keep = clamp(structure - 1, 0, 6).float / 6 * 0.7
    let blend = clamp(color, 0, 10).float / 10
    for i in 0 ..< healed.px.len:
      if mask[i] == 0: continue
      let a = mix(healed.px[i], src.px[i], keep)
      healed.px[i] = mix(a, healed.px[i], blend * (1 - keep))
  if transparent:
    for i in 0 ..< healed.px.len:
      if mask[i] > 0: healed.px[i] = mix(dst.px[i], healed.px[i], 0.5)
  if destination:
    # (the selection goes with the patch, as Photoshop's: it is where the
    # pixels went in)
    var moved = newSeq[uint8](d.w * d.h)
    for y in 0 ..< d.h:
      let sy = y - dy
      if sy < 0 or sy >= d.h: continue
      for x in 0 ..< d.w:
        let sx = x - dx
        if sx >= 0 and sx < d.w: moved[y * d.w + x] = d.sel[sy * d.w + sx]
    d.touchSel()
    d.sel = moved
    inc d.selVer
  var all = newSeq[uint8](r.w * r.h)
  for v in all.mitems: v = 255
  d.putBack(L, r, dst, healed, all)

proc redEye*(d: Doc; x, y, radius: int; darken = 50) =
  ## The Red Eye tool at `x`, `y` (an undo step must be open).
  let L = d.layer
  let r = d.clip(rect(x - 2 * radius, y - 2 * radius, 4 * radius + 1, 4 * radius + 1))
  if r.w <= 0 or r.h <= 0: return
  let src = d.layerImg(L, r)
  let o = redEye(src, x - r.x, y - r.y, radius, darken)
  var amount = newSeq[uint8](r.w * r.h)
  for i in 0 ..< amount.len: amount[i] = uint8(d.selAt((r.y + i div r.w) * d.w + r.x + i mod r.w))
  d.putBack(L, r, src, o, amount)

proc selectSubject*(d: Doc): seq[uint8] =
  ## Select > Subject, of the image as it looks (a mask as big as it).
  d.updateComposite()
  selectSubject(Img(w: d.w, h: d.h, px: d.compCopy))

proc removeBackground*(d: Doc): seq[uint8] =
  ## Remove Background: the subject of the current layer (else of the
  ## image as it looks), its hair and fur followed -- the mask to put on
  ## the layer. 0..255 per pixel.
  d.updateComposite()
  let L = d.current
  let own = L.px.len == d.w * d.h and not L.group and L.adjust.kind.len == 0
  let src = if own: Img(w: d.w, h: d.h, px: L.px) else: Img(w: d.w, h: d.h, px: d.compCopy)
  refineHair(src, selectSubject(src))

proc selectSky*(d: Doc): seq[uint8] =
  ## Select > Sky, of the image as it looks.
  d.updateComposite()
  selectSky(Img(w: d.w, h: d.h, px: d.compCopy))

# ---- enlarging with the detail kept -----------------------------------------------------------------------

proc enlarge*(d: Doc; nw, nh: int; reduceNoise = 0; dpi = 0.0) =
  ## Image Size with Preserve Details: the image made bigger (Lanczos),
  ## then its edges and texture made crisp again for the new size, and its
  ## noise (`reduceNoise`, 0..100) not made bigger with it. (Undoable:
  ## `snapStep` first.) Raises `ValueError` when too big.
  let k = max(nw / max(1, d.w), nh / max(1, d.h))
  d.imageSize(nw, nh, rsLanczos, dpi)
  if k <= 1.05: return
  let radius = clamp(0.45 * k, 0.6, 3.0)
  for L in d.layers:
    if L.gray: continue                       # (an adjustment layer's mask)
    let im = Img(w: d.w, h: d.h, px: L.px)
    L.px = detailImg(im, reduceNoise, reduceNoise div 2, 70, radius).px
    inc L.ver
  d.markAll()

# ---- Content-Aware Scale (seams) --------------------------------------------------------------------------

proc transposed(im: Img): Img =
  result = newImg(im.h, im.w)
  for y in 0 ..< im.h:
    for x in 0 ..< im.w: result.px[x * im.h + y] = im.px[y * im.w + x]

proc transposedMask(m: seq[uint8]; w, h: int): seq[uint8] =
  if m.len < w * h: return
  result = newSeq[uint8](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w: result[x * h + y] = m[y * w + x]

proc seamColumns(small: Img; protect: seq[uint8]; target: int): seq[seq[int32]] =
  ## For each row of `small`, the columns kept (in order, some twice when it
  ## grows) to make it `target` wide: the seams of least energy taken out
  ## or doubled, what is protected (`protect`, 0..255) spared.
  let w = small.w
  let h = small.h
  var lum = newSeq[float32](w * h)
  for i in 0 ..< w * h:
    let p = small.px[i]
    lum[i] = 0.299'f32 * rOf(p).float32 + 0.587'f32 * gOf(p).float32 + 0.114'f32 * bOf(p).float32
  var guard = newSeq[float32](w * h)
  if protect.len == w * h:
    for i in 0 ..< w * h: guard[i] = protect[i].float32 * 40
  # what stands out (the subject) is spared too
  var lab = newSeq[Col](w * h)
  for i in 0 ..< w * h: lab[i] = labOf(small.px[i])
  let sal = subjectSaliency(lab, w, h)
  for i in 0 ..< w * h: guard[i] += sal[i] * sal[i] * 90
  # the current picture: per row, which columns are still there
  var cols = newSeq[seq[int32]](h)
  for y in 0 ..< h:
    cols[y] = newSeq[int32](w)
    for x in 0 ..< w: cols[y][x] = int32(x)
  let k = abs(target - w)
  let removing = target < w
  var removed = newSeq[seq[int32]](h)              # (growing: the seams to double, in order)
  var cw = w
  var cost = newSeq[float32](w * h)
  var back = newSeq[int8](w * h)
  for s in 0 ..< min(k, w - 2):
    # the energy of what is left (forward: what removing a pixel joins)
    for y in 0 ..< h:
      for x in 0 ..< cw:
        let l = lum[y * w + cols[y][max(x - 1, 0)]]
        let r = lum[y * w + cols[y][min(x + 1, cw - 1)]]
        let up = if y > 0: lum[(y - 1) * w + cols[y][x]] else: lum[y * w + cols[y][x]]
        let cu = abs(r - l)
        let e = guard[y * w + cols[y][x]]
        if y == 0:
          cost[x] = cu + e
          continue
        var best = cost[(y - 1) * w + x] + cu
        var b: int8 = 0
        if x > 0:
          let cl = cu + abs(up - l)
          let v = cost[(y - 1) * w + x - 1] + cl
          if v < best: best = v; b = -1
        if x + 1 < cw:
          let cr = cu + abs(up - r)
          let v = cost[(y - 1) * w + x + 1] + cr
          if v < best: best = v; b = 1
        cost[y * w + x] = best + e
        back[y * w + x] = b
    # the cheapest seam, from the bottom up
    var x = 0
    for i in 1 ..< cw:
      if cost[(h - 1) * w + i] < cost[(h - 1) * w + x]: x = i
    for y in countdown(h - 1, 0):
      removed[y].add cols[y][x]
      cols[y].delete(x)
      if y > 0: x = clamp(x + int(back[y * w + x]), 0, cw - 2)
    dec cw
  if removing:
    return cols
  # growing: the seams found (the cheapest first) each doubled
  result = newSeq[seq[int32]](h)
  for y in 0 ..< h:
    var twice = newSeq[int](w)
    for c in removed[y]: inc twice[c]
    var extra = k - removed[y].len                  # (more than the seams found: spread evenly)
    for x in 0 ..< w:
      result[y].add int32(x)
      for t in 0 ..< twice[x]: result[y].add int32(x)
    var i = 0
    while extra > 0 and result[y].len > 0:
      let at = (i * 7919) mod result[y].len
      result[y].insert(result[y][at], at)
      dec extra
      inc i

proc scaleWidth(imgs: var seq[Img]; gi, pi: int; nw: int) =
  ## Every picture in `imgs` (all of a size) made `nw` wide by the seams of
  ## `imgs[gi]`, sparing what `imgs[pi]` (when >= 0: gray) protects.
  let guide = imgs[gi]
  let w = guide.w
  let h = guide.h
  if nw == w or w < 3: return
  # (the seams on a small copy; their places read big)
  let f = max(1.0, w / 480)
  let side = max(1, int(max(w, h).float / f))
  let small = smallCopy(guide, side)
  let sw = small.w
  let sh = small.h
  var sp: seq[uint8]
  if pi >= 0:
    let ps = smallCopy(imgs[pi], side)
    sp = newSeq[uint8](sw * sh)
    for i in 0 ..< sw * sh: sp[i] = uint8(rOf(ps.px[i]))
  let target = max(2, int(round(nw.float * sw.float / w.float)))
  let kept = seamColumns(small, sp, target)
  let fx = w / sw
  # for each row: where each new column comes from
  var srcX = newSeq[float32](nw * sh)
  for sy in 0 ..< sh:
    let row = kept[sy]
    let n = row.len
    for x in 0 ..< nw:
      let j = (x.float + 0.5) * n.float / nw.float
      let ji = clamp(int(j), 0, n - 1)
      srcX[sy * nw + x] = float32((row[ji].float + (j - ji.float)) * fx - 0.5)
  for L in imgs.mitems:
    var o = newImg(nw, h)
    for y in 0 ..< h:
      let sy = clamp(int((y.float + 0.5) * sh.float / h.float), 0, sh - 1)
      for x in 0 ..< nw:
        let sx = clamp(srcX[sy * nw + x].float, 0.0, float(w - 1))
        let x0 = int(sx)
        let x1 = min(x0 + 1, w - 1)
        o.px[y * nw + x] = mix(L.px[y * w + x0], L.px[y * w + x1], sx - x0.float)
    L = o

proc skinMask*(im: Img): seq[uint8] =
  ## Where the picture looks like skin (0..255).
  result = newSeq[uint8](im.w * im.h)
  for i, p in im.px:
    let r = rOf(p)
    let g = gOf(p)
    let b = bOf(p)
    if r > 95 and g > 40 and b > 20 and r > g and r > b and r - min(g, b) > 15 and abs(r - g) > 15:
      result[i] = 255

proc contentAwareScale*(d: Doc; nw, nh: int; protect: seq[uint8] = @[]) =
  ## Edit > Content-Aware Scale: the image made `nw` x `nh` by taking out
  ## (or doubling) the paths of least detail across it, so what matters
  ## keeps its shape; `protect` (as big as the image, 0..255) is spared.
  ## (Undoable: `snapStep` first.) Raises `ValueError` when too big.
  if nw < 2 or nh < 2: return
  if not sizeOk(nw, nh): raise newException(ValueError, "too big")
  d.rasterizeAllText()
  d.updateComposite()
  var imgs: seq[Img]
  for L in d.pixelLayers: imgs.add Img(w: d.w, h: d.h, px: L.px)
  # (the channels and the selection go along as pictures of gray)
  for a in d.alphas:
    var im = newImg(d.w, d.h)
    for i in 0 ..< d.w * d.h: im.px[i] = grayPx(int(a.m[i]))
    imgs.add im
  let hadSel = d.hasSelection
  if hadSel:
    var im = newImg(d.w, d.h)
    for i in 0 ..< d.w * d.h: im.px[i] = grayPx(int(d.sel[i]))
    imgs.add im
  let gi = imgs.len
  imgs.add Img(w: d.w, h: d.h, px: d.compCopy)
  var pi = -1
  if protect.len == d.w * d.h:
    pi = imgs.len
    var im = newImg(d.w, d.h)
    for i in 0 ..< d.w * d.h: im.px[i] = grayPx(int(protect[i]))
    imgs.add im
  # across, then (turned) down
  scaleWidth(imgs, gi, pi, nw)
  for im in imgs.mitems: im = transposed(im)
  scaleWidth(imgs, gi, pi, nh)
  for im in imgs.mitems: im = transposed(im)
  var k = 0
  for L in d.pixelLayers:
    L.px = imgs[k].px
    inc L.ver
    inc k
  for a in d.alphas.mitems:
    a.m = newSeq[uint8](nw * nh)
    for i in 0 ..< nw * nh: a.m[i] = uint8(rOf(imgs[k].px[i]))
    inc k
  if hadSel:
    var m = newSeq[uint8](nw * nh)
    for i in 0 ..< nw * nh: m[i] = uint8(rOf(imgs[k].px[i]))
    d.sel = m
  d.paths.setLen(0)
  d.curPath = -1
  d.w = nw
  d.h = nh
  inc d.selVer
  d.comp = @[]
  d.markAll()
